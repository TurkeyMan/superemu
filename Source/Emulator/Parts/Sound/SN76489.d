module demu.emulator.parts.sound.sn76489;

import demu.emulator.machine;
import demu.emulator.parts.soundpart;

import core.thread;

/*** TODO: REFACTOR ***/
/*** TODO: missing versions ***/

class SN76489 : SoundPart
{
	enum Version
	{
		SN76489,		// inverted waveform
		SN76489A,
		SN76489_SMS,	// different white noise
		SN76489_SGG,	// stereo output
		NCR7496,		// tandy clone (different white noise)
		NCR8496
	}

	this(Machine machine, string name, Version revision, float clockfreq, bool bSwapbits = false, int samplerate = 48000, float pan = 0.f)
	{
		this.revision = revision;

		this.bSwapBits = bSwapbits;
		int iClockFreq = cast(int)(clockfreq * 1000000.f);
		clocksPerSample = 1 + (iClockFreq << 4) / samplerate;	// No. of main clocks between each sampling instant as a 4 bit fixed point
		internalClocksPerToggle = clocksPerSample >> 4;			// internal divide by 16

		noiseW = new ubyte[NOISE_BUFFER_SIZE];	// white noise
		noiseP = new ubyte[NOISE_BUFFER_SIZE];	// periodic noise
		InitNoiseBuffer();
		Reset();

		//GenerateSamples(MAX_SAMPLE_INDEX);   // make sure we have some in the buffer before we init the MK sound

		super(machine, name, clockfreq, 1, pan, samplerate, 0);
	}

	uint Reset()
	{
		Init();
		return super.Reset();
	}

	void Write(ubyte value)
	{
		// need to flip the bits in the byte for data, stupid chip !
		if(bSwapBits)
			value = flipTable[value];

		// if bit7 is 1, then it's a register address and high bits of data write. If 0, then it's a data write to the existing selected register
		if(value&0x80)
		{
			regs.regSelect = (value>>4)&0x7;
			final switch(regs.regSelect)
			{
				case 0: // tone1 low freq bits 0..3
					regs.tone[0] &= 0xff0;
					regs.tone[0] |= (value&0x0f);
					SetSampleRate(Channel.CH_1);
					break;
				case 1: // attenuation1
					regs.attenuation[0] = value&0xf;
					chVolume[Channel.CH_1] = (DBtoVolume[(value&0xf)]*SAMPLESCALE)>>8;	// convert dB attenuation, into final output volume
					break;
				case 2: // tone2 low freq bits 0..3
					regs.tone[1] &= 0xff0;
					regs.tone[1] |= (value&0x0f);
					SetSampleRate(Channel.CH_2);
					break;
				case 3: // attenuation2
					regs.attenuation[1] = value&0xf;
					chVolume[Channel.CH_2] = (DBtoVolume[(value&0xf)]*SAMPLESCALE)>>8;	// convert dB attenuation, into final output volume
					break;
				case 4: // tone3 lowfreq bits 0..3
					regs.tone[2] &= 0xff0;
					regs.tone[2] |= (value&0x0f);
					SetSampleRate(Channel.CH_3);
					break;
				case 5: // attenuation3
					regs.attenuation[2] = value&0xf;
					chVolume[Channel.CH_3] = (DBtoVolume[(value&0xf)]*SAMPLESCALE)>>8;	// convert dB attenuation, into final output volume
					break;
				case 6: // Noise control
					regs.noiseControl = value&0xf;
					SetNoiseRate();
					break;
				case 7: // Noise attenuation
					regs.noiseAttenuation = value&0xf;
					noiseVolume = (DBtoVolume[(value&0xf)]*SAMPLESCALE)>>8;	// convert dB attenuation, into final output volume
					break;
			}
		}
		else    // bit 0 was clear, so it's a data write to the previously selected register
		{
			final switch(regs.regSelect)
			{
				case 0: // tone1 freq high bits 6..9
					regs.tone[0] &= 0x0f;
					regs.tone[0] |= ((value&0x3f)<<4);
					SetSampleRate(Channel.CH_1);
					//toneState[CH_1] ^= 0x1;	// flip the state of the bit
					break;
				case 1: // attenuation1
					regs.attenuation[0] = value&0xf;
					chVolume[Channel.CH_1] = (DBtoVolume[(value&0xf)]*SAMPLESCALE)>>8;	// convert dB attenuation, into final output volume
					break;
				case 2: // tone2 freq high bits 6..9
					regs.tone[1] &= 0x0f;
					regs.tone[1] |= ((value&0x3f)<<4);
					SetSampleRate(Channel.CH_2);
					//toneState[CH_2] ^= 0x1;	// flip the state of the bit
					break;
				case 3: // attenuation2
					regs.attenuation[1] = value&0xf;
					chVolume[Channel.CH_2] = (DBtoVolume[(value&0xf)]*SAMPLESCALE)>>8;	// convert dB attenuation, into final output volume
					break;
				case 4: // tone3 freq high bits 6..9
					regs.tone[2] &= 0x0f;
					regs.tone[2] |= ((value&0x3f)<<4);
					SetSampleRate(Channel.CH_3);
					//toneState[CH_3] ^= 0x1;	// flip the state of the bit
					break;
				case 5: // attenuation3
					regs.attenuation[2] = value&0xf;
					chVolume[Channel.CH_3] = (DBtoVolume[(value&0xf)]*SAMPLESCALE)>>8;	// convert dB attenuation, into final output volume
					break;
				case 6: // Noise control
					regs.noiseControl = value&0xf;
					SetNoiseRate();
					break;
				case 7: // Noise attenuation
					regs.noiseAttenuation = value&0xf;
					noiseVolume = (DBtoVolume[(value&0xf)]*SAMPLESCALE)>>8;	// convert dB attenuation, into final output volume
					break;
			}
		}
	}

	void GenerateSamples(int numSamples)
	{
		LockBuffer();

		int bufferSpace = GetVacantSamples();

		// make sure we have enough space in our buffer
		while(bufferSpace < numSamples)
		{
			UnlockBuffer();
			Thread.sleep(dur!"msecs"(1));
			LockBuffer();

			bufferSpace = GetVacantSamples();
		}

		while(numSamples--)
		{
			ClockNoise(clocksPerSample);

			// sum all three channels
			int sample = CalcOneSample(Channel.CH_1);
			sample += CalcOneSample(Channel.CH_2);  // looking on the oscilloscope, they appear to do a proper ADD, not an average
			sample += CalcOneSample(Channel.CH_3);

			int noise = ((cast(int)noise[noiseIndex] << 1) - 1)*noiseVolume;    // include the noise
			sample += noise;
			sample += auxInput * SAMPLESCALE;

			samplesL[writeCursor++] = sample;
			writeCursor %= SOUNDBUFFER_SIZE;
		}

		UnlockBuffer();
	}

protected:

	Version revision;

	// state data
	Registers regs;
	int noiseVolume;
	int auxInput;		// for external audio feed through (auxiliary DtoA)

	// runtime data
	ubyte[] noise;
	ubyte[] noiseW;
	ubyte[] noiseP;
	float prevSample;

	int clocksPerSample;
	int internalClocksPerToggle;

	int[3] currChannelCount; // current counter for each channel (when <=0 then toggle bit)
	int[3] chMaxCount;       // Count value to reset the channel to when it toggled
	int[3] chMasterCount;
	int[3] toneState;        // current state of the tone generator part for the channel (will be 0 or 1)
	int[3] chVolume;
	int currNoiseCount;
	int maxNoiseCount;
	int masterNoiseCount;
	int noiseIndex;
	bool bSwapBits;

	void Init() nothrow
	{
		regs.tone[0] = 0;
		regs.attenuation[0] = 0xf;       // 0x0f is OFF
		regs.tone[1] = 0;
		regs.attenuation[1] = 0xf;
		regs.tone[2] = 0;
		regs.attenuation[2] = 0xf;
		regs.noiseControl = 0;
		regs.noiseAttenuation = 0xf;
		regs.regSelect = 0;

		chMasterCount[Channel.CH_1] = 0;
		chMasterCount[Channel.CH_2] = 0;
		chMasterCount[Channel.CH_3] = 0;
		chMaxCount[Channel.CH_1] = 0;
		chMaxCount[Channel.CH_2] = 0;
		chMaxCount[Channel.CH_3] = 0;
		currChannelCount[Channel.CH_1] = 0;
		currChannelCount[Channel.CH_2] = 0;
		currChannelCount[Channel.CH_3] = 0;
		toneState[Channel.CH_1] = 1;
		toneState[Channel.CH_2] = 1;
		toneState[Channel.CH_3] = 1;
		chVolume[Channel.CH_1] = 0;
		chVolume[Channel.CH_2] = 0;
		chVolume[Channel.CH_3] = 0;
		currNoiseCount = 0;
		masterNoiseCount = 1;   // just so it doesn't use CH3 as the clock initially
		noiseIndex = 0;
		noiseVolume = 0;
		auxInput = 0;
		SetSampleRates();
		prevSample = 0.0f;
		noise = noiseW;
	}


/*
	//dB  amplitude
	0     1.0
	2     .79
	4     .63
	6     .50

	8     .40
	10    .32
	12    .25
	14    .2

	16    .16
	18    .13
	20    .1
	22    .08

	24    .06
	26    .05
	28    .04
	off   0
*/
	// conversion table for dB attenuation, to final voltage (as a 24:8 fixed point)
	immutable int[16] DBtoVolume =
	[
		256,202,161,128,    // 0, 2, 4, 6
		102,82, 64, 51,     // 8, 10,12,14
		41, 33, 26, 20,     // 16,18,20,22
		15, 13, 10, 0       // 24,26,28,OFF
	];

	void SetSampleRate(Channel ch) nothrow
	{
		chMasterCount[ch] = regs.tone[ch]<<4;    // as a 4 bit fraction
	}

	void SetSampleRates() nothrow
	{
		SetSampleRate(Channel.CH_1);
		SetSampleRate(Channel.CH_2);
		SetSampleRate(Channel.CH_3);
	}

	void SetNoiseRate()
	{
		switch(regs.noiseControl&0x3)
		{
			case 0:                         // 1/64 input clock
				masterNoiseCount = 0x400;   // 64 clocks as a 4 bit fixed point
				break;
			case 1:                         // 1/128 input clock
				masterNoiseCount = 0x800;   // 128 clocks as a 4 bit fixed point
				break;
			case 2:                         // 1/256 input clock
				masterNoiseCount = 0x1000;  // 256 clocks as a 4 bit fixed point
				break;
			case 3:
			default:
				masterNoiseCount = 0;   // use Tone3
				break;
		}
		currNoiseCount = 0;

		if(regs.noiseControl & 0x4)
			noise = noiseW;	// White Noise
		else
			noise = noiseP;	// Periodic Noise
	}

	void ClockNoise(int clocks)
	{
		if(masterNoiseCount > 0) // make sure it's not using Tone3 to clock it
		{
			currNoiseCount += clocks;
			if(currNoiseCount >= maxNoiseCount)
			{
				++noiseIndex;						// step through noise array
				noiseIndex &= (NOISE_BUFFER_SIZE-1);
				currNoiseCount -= maxNoiseCount;	// reset counter
				maxNoiseCount = masterNoiseCount;	// reset the max in case they changed it
				currNoiseCount &= 0x1ff;			// just to limit it in case they change it radically
			}
		}
	}

	void InitNoiseBuffer()
	{
		// Init the White noise buffer
		ubyte[] dest = noiseW;
		uint rnd = 0x1;
		foreach(i; 0..NOISE_BUFFER_SIZE)
		{
			int bit16 = rnd&0x9;	// for tap points at bits 0 and 3
			bit16 ^= bit16>>8;
			bit16 ^= bit16>>4;
			bit16 ^= bit16>>2;
			bit16 ^= bit16>>1;
			bit16 &= 0x1;
			rnd = (bit16 << 15) | ((rnd >> 1) & 0x7fff);
			dest[i] = cast(ubyte)rnd & 0x1;
		}
		// And now init the Periodic noise buffer (basically 1 bit on in every 16)
		dest = noiseP;
		rnd = 0x1;
		foreach(i; 0..NOISE_BUFFER_SIZE)
		{
			dest[i] = cast(ubyte)rnd & 0x1;
			rnd = (rnd<<1) | (rnd>>16);
		}
		noise = noiseP;   // default to use Periodic noise
	}

	void WriteAuxInput(ubyte audiolevel)
	{
		auxInput = cast(int)0x080 - audiolevel;
	}

	short CalcOneSample(int channelNum)
	{
		assert(channelNum <= cast(int)Channel.CH_3 ,"Invalid channel number");
		if(channelNum <= cast(int)Channel.CH_3)
		{
			short volume = cast(short)chVolume[channelNum];
			ubyte enabTone=0;
			ubyte enabNoise=0;
			if(chMasterCount[channelNum] <= internalClocksPerToggle)
			{
				toneState[channelNum] = 1;	// values of 0 or 1, lock the output to a 1, for sample playback using the volume
			}
			else
			{
				currChannelCount[channelNum] += internalClocksPerToggle;
				if(currChannelCount[channelNum] >= chMaxCount[channelNum])
				{
					toneState[channelNum] ^= 0x1;								// toggle the tone generator state between 0 and 1
					currChannelCount[channelNum] -= chMaxCount[channelNum];		// reset counter
					chMaxCount[channelNum] = chMasterCount[channelNum];			// reset the max in case they changed it
					currChannelCount[channelNum] &= 0x1fff;						// just to limit it in case they change it radically
					if((masterNoiseCount == 0) && (channelNum == Channel.CH_3))	// noise using Tone3 to clock it ?
					{
						//if(toneState[CH_3] ==1)		// only clock it on rising edges
						{
							++noiseIndex;				// step through noise array
							noiseIndex &= (NOISE_BUFFER_SIZE-1);
						}
					}
				}
			}
			short retval = cast(short)(((toneState[channelNum] << 1) - 1) * volume);
			return retval;
		}
		return 0;
	}
}

private:

enum Channel
{
	CH_1 = 0,
	CH_2 = 1,
	CH_3 = 2,
}

enum Regs
{
	INVALID = -1,
	TONE_1 = 0,
	ATTENUATION_1,
	TONE_2,
	ATTENUATION_2,
	TONE_3,
	ATTENUATION_3,
	NOISECONTROL,
	NOISEATTENUATION,
}

enum int SAMPLECLAMP = 32760;			// A whisker less than full deflection
enum int SAMPLESCALE = 32760 / 3;		// Lets do each one as 1/3 volume, so the channels can add with reduced risk of clamping
enum int NOISE_BUFFER_SIZE = 0x1000;

struct Registers
{
	ushort[3] tone;
	ushort[3] attenuation;
	ushort noiseControl;
	ushort noiseAttenuation;
	ushort regSelect;	// NOTE: this is not strictly an accessible AY3 register, but is internal to choose which reg to read/write
}

static immutable ubyte[256] flipTable =
{
	ubyte[256] flip;
	foreach(i; 0..256)
		flip[i] = cast(ubyte)(255 - i);
	return flip;
}();

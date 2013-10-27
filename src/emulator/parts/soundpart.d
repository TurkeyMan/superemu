module demu.emulator.parts.soundpart;

import demu.emulator.machine;
import demu.emulator.parts.part;
import demu.emulator.parts.processor;

import std.algorithm;
import core.sync.mutex;

class SoundPart : Processor
{
	this(Machine machine, string name, float clockRate, int numChannels, float pan, uint sampleRate, uint features)
	{
		super(machine, name, features);

		this.sampleRate = sampleRate;
		this.clockRate = cast(int)(clockRate * 1000000.0f);
		samplesPerFrame = sampleRate / 60;
		ticksPerSample = this.clockRate / sampleRate;

		this.numChannels = numChannels;
		this.pan = pan;
		outputLevel = 1.0f;

		resampleCounter = 0;
		mutex = new Mutex;

//		pPSGStream = CreateWaveUnit(pName, "EmuSoundSubBus", 2, _sampleRate, GetSamples, this, true);
	}

	@property int SampleRate() const nothrow { return sampleRate; }
	@property int ClockRate() const nothrow { return clockRate; }

	@property int SamplesPerFrame() const nothrow { return samplesPerFrame; }
	@property int ClocksPerSample() const nothrow { return ticksPerSample; }

	@property float SetOutputLevel() const nothrow { return outputLevel; }
	@property void SetOutputLevel(float level) nothrow { outputLevel = level; }

	int BeginFrame()
	{
		samplesRemaining = samplesPerFrame;

		// calculate the buffer level
		uint bufferLevel = (writeCursor + (playCursor > writeCursor ? SOUNDBUFFER_SIZE : 0)) - playCursor;

		// calculate drift compensation
		int compensation = (SOUNDBUFFER_SIZE / 2) - cast(int)bufferLevel;
		if(compensation >= -800 && compensation <= 800)
			compensation = 0;
		compensation >>= 3;

		// update the frame counters
		samplesRemaining += compensation;
		ticksPerSample = clockRate / (samplesRemaining * 60);

		// float pc = ((float)bufferLevel / (float)SOUNDBUFFER_SIZE) * 100.0f;
		// Logf("Begin %s: %d (%d), level: %d (%g%%%%)", name, samplesRemaining, compensation, bufferLevel, pc);

		return samplesRemaining;
	}

	void FinishFrame(int remaining)
	{
		if(remaining == -1)
		{
			remaining = samplesRemaining;
			samplesRemaining = 0;
		}

		// Logf("Finish %s: %d remaining", name, remaining);

		if(remaining > 0)
			GenerateSamples(remaining);
	}

	override int Execute(int numCycles, uint breakConditions)
	{
		int cc = 0;
		int numSamples = 0;

		do
		{
			++numSamples;
			cc += ticksPerSample;
			numCycles -= ticksPerSample;
		}
		while(numCycles >= 0);

		if(samplesRemaining > 0)
			GenerateSamples(numSamples);
		samplesRemaining -= numSamples;

		cycleCount += cc;
		return cc;
	}

	abstract void GenerateSamples(int numSamples);

protected:
	uint writeCursor;
	uint playCursor;

	enum int SOUNDBUFFER_SIZE = 4800;
	float[SOUNDBUFFER_SIZE] samplesL;
	float[SOUNDBUFFER_SIZE] samplesR;

	int samplesRemaining;

	void LockBuffer()
	{
		mutex.lock();
	}
	void UnlockBuffer()
	{
		mutex.unlock();
	}

	int GetFilledSamples() { return writeCursor < playCursor ? writeCursor + (SOUNDBUFFER_SIZE - playCursor) : writeCursor - playCursor; }
	int GetVacantSamples() { return writeCursor < playCursor ? playCursor - writeCursor - 1 : playCursor + (SOUNDBUFFER_SIZE - writeCursor - 1); }

private:
	int GetSamples(int numChannels, float* pSamples, int numRequested, void* pUserData)
	{
		LockBuffer();

		int numAvailable = min(GetFilledSamples(), numRequested);

		if(numAvailable < numRequested)
		{
			// Logf("Starvation!!: %s", pSC->name);

			GenerateSamples(numRequested - numAvailable);
			numAvailable = numRequested;
		}

		float volL = clamp(0.0f, 1.0f - pan, 1.0f) * outputLevel;
		float volR = clamp(0.0f, 1.0f + pan, 1.0f) * outputLevel;
		float[] right = numChannels == 1 ? samplesL : samplesR;

		while(numAvailable--)
		{
			pSamples[0] = samplesL[playCursor] * volL;
			pSamples[1] = right[playCursor++] * volR;
			playCursor %= SOUNDBUFFER_SIZE;
			pSamples += 2;
		}

		UnlockBuffer();

		return numRequested;
	}

//	static int GetSamplesMono(int numChannels, float* pSamples, int numRequested, void* pUserData);
//	static int GetSamplesResample(int numChannels, float* pSamples, int numRequested, void* pUserData);
//	static int GetSamplesResampleMono(int numChannels, float* pSamples, int numRequested, void* pUserData);

//	SEWaveUnit* pPSGStream;
	Mutex mutex;
	ushort resampleCounter;

	uint sampleRate;
	int numChannels;
	float pan;
	float outputLevel;

	int clockRate;
	int samplesPerFrame;
	int ticksPerSample;
}

module demu.emulator.parts.io.mos6532;

import demu.emulator.machine;
import demu.emulator.parts.part;
import demu.emulator.parts.processor;

class MOS6532 : Part
{
	alias void delegate(Port port, ubyte data) WriteDelegate;

	enum Port
	{
		A,
		B
	}

	enum Register
	{
		Swcha,	// Port A data
		Swacnt,	// Port A DDR
		Swchb,	// Port B data
		Swbcnt,	// Port B DDR
		Intim,	// Timer output
		Timint	// Timer interrupt
	}

	this(Machine machine, string name, Processor cpu)
	{
		super(machine, name, Part.Feature.Registers);

		regInfo = sRegInfo;

		this.cpu = cpu;

		state[0] = state[1] = 0xFF;
		timer = 0x6D << 10;//randomInt(1, 256) << 10;
		interval = 10;
	}

	@property void OnWrite(WriteDelegate callback) { writeCallback = callback; }
	@property WriteDelegate OnWrite() { return writeCallback; }

	ubyte[] GetRam() { return ram; }

	void SetPortState(Port port, ubyte state)
	{
		this.state[port] = state;
	}

	ubyte Read(uint address)
	{
		final switch(address & 7)
		{
			case Register.Swcha:
				return state[0] & (~ddr[0] | (writeState[0] & ddr[0]));
			case Register.Swacnt:
				return ddr[0];
			case Register.Swchb:
				return (state[1] & ~ddr[1]) | (writeState[1] & ddr[1]);
			case Register.Swbcnt:
				return ddr[1];
			case Register.Intim:
			case 0x6: // appears to be a mirror
			{
/*
				// some doco claims that reading this address with A3 set enables the interrupt, but does this 'enable' or 'flag' the interrupt?
				if(address & 8)
					// enable interrupt
				else
					// disable interrupt
*/
				timerInterruptPending = false;

				long t = timer - (cpu.CycleCount - timerStart);
				if(t >= 0)
					return (t >> interval) & 0xFF;
				else
				{
					if(t != -1)
						timerInterruptPending = true;
					return t & 0xFF;
				}
			}
			case Register.Timint:
			case 0x7: // appears to be a mirror
			{
				if((enableTimerInterrupt && timerInterruptPending) || timer >= cpu.CycleCount - timerStart)
					return 0x00;
				else
					return 0x80;
			}
		}

		return 0;
	}

	void Write(uint address, ubyte value)
	{
		if(address & 0x4)
		{
			if(address & 0x10)
			{
				// set the timer
				static immutable int[4] intervalShift = [ 0, 3, 6, 10 ];

				interval = intervalShift[address & 3];
				timer = value << interval;
				timerStart = cpu.CycleCount;

				// enable timer interrupt
				enableTimerInterrupt = !!(address & 8);
				timerInterruptPending = false;
			}
			else
			{
				// edge detect control O_o ?!? is this useful?
				// address & 3:
				//  0 = negative edge, disable int
				//  1 = positive edge, disable int
				//  2 = negative edge, enable int
				//  3 = positive edge, enable int
			}
		}
		else
		{
			final switch(address & 0x3)
			{
				case Register.Swcha:
					writeState[0] = value;
					if(writeCallback)
						writeCallback(Port.A, value & ddr[0]);
					break;
				case Register.Swacnt:
					ddr[0] = value;
					break;
				case Register.Swchb:
					writeState[1] = value;
					if(writeCallback)
						writeCallback(Port.B, value & ddr[1]);
					break;
				case Register.Swbcnt:
					ddr[1] = value;
					break;
			}
		}
	}

	ubyte ReadRam(uint address)
	{
		return ram[address & 0x7F];
	}

	void WriteRam(uint address, ubyte value)
	{
		ram[address & 0x7F] = value;
	}

	override uint GetRegisterValue(int reg)
	{
		return Read(reg);
	}

	override void SetRegisterValue(int reg, uint value)
	{
		switch(reg)
		{
			case 0:
				state[0] = cast(ubyte)value;
				Write(Register.Swcha, cast(ubyte)value);
				break;
			case 1:
				ddr[0] = cast(ubyte)value;
				break;
			case 2:
				state[1] = cast(ubyte)value;
				Write(Register.Swchb, cast(ubyte)value);
				break;
			case 3:
				ddr[1] = cast(ubyte)value;
				break;
			case 4:
				Write(Register.Intim, cast(ubyte)value);
				break;
			case 5:
				Write(Register.Timint, cast(ubyte)value);
				break;
			default:
				break;
		}
	}

private:
	ubyte[128] ram;

	ubyte[2] ddr;
	ubyte[2] state;
	ubyte[2] writeState;

	int interval;
	long timer;
	long timerStart;
	bool enableTimerInterrupt;
	bool timerInterruptPending;

	Processor cpu;
	WriteDelegate writeCallback;
}

private:

static immutable RegisterInfo[] sRegInfo =
[
	RegisterInfo( "Swcha",  8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "Swacnt", 8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "Swchb",  8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "Swbcnt", 8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "Intim",  8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "Timint", 8, RegisterInfo.Flags.ReadOnly, null ),
];

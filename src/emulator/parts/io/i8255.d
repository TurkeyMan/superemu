module demu.emulator.parts.io.i8255;

import demu.emulator.machine;
import demu.emulator.parts.part;

/*** TODO: missing modes ***/

class I8255 : Part
{
	alias void delegate(Port port, ubyte data, ubyte mask) WriteDelegate;

	enum Port
	{
		A,
		B,
		C
	}

	enum Register
	{
		PortA,
		PortB,
		PortC,
		Control
	}

	this(Machine machine, string name)
	{
		super(machine, name, Part.Feature.Registers);

		regInfo = sRegInfo;

		Reset();
	}

	void Reset()
	{
		portA = 0xff;
		portB = 0xff;
		portC = 0xff;
		cntrl = 0x9B;
	}

	@property void OnWrite(WriteDelegate callback) { writeCallback = callback; }
	@property WriteDelegate OnWrite() { return writeCallback; }

	void SetPortBits(Port port, ubyte bits)
	{
		if(port == Port.A)
			portA |= bits;
		else if(port == Port.B)
			portB |= bits;
		else if(port == Port.C)
			portC |= bits;
	}

	void ClearPortBits(Port port, ubyte bits)
	{
		if(port == Port.A)
			portA &= ~bits;
		else if(port == Port.B)
			portB &= ~bits;
		else if(port == Port.C)
			portC &= ~bits;
	}

	void SetPortState(Port port, ubyte state)
	{
		if(port == Port.A)
			portA = state;
		else if(port == Port.B)
			portB = state;
		else if(port == Port.C)
			portC = state;
	}

	ubyte Read(uint address)
	{
		ubyte state = 0xFF;

		final switch(address & 0x3)
		{
			case 0:
				// is Port A an input?
				if((cntrl & 0x10) != 0)
					state = portA;
				break;
			case 1:
				// is Port B an input?
				if((cntrl & 0x02) != 0)
					state = portB;
				break;
			case 2:
				// port C Lower DDR (0 = output)
				if((cntrl & 0x1) != 0)     
				{
					state &= 0xF0;
					state |= portC&0x0F;
				}

				// port C Upper DDR (0 = output)
				if((cntrl & 0x8) != 0)     
				{
					state &= 0x0F;
					state |= portC&0xF0;
				}
				break;
			case 3:
				state = cntrl | 0x80; // Bit 7 always 1
				break;
		}

		return state;
	}

	void Write(uint address, ubyte value)
	{
		final switch(address & 0x3)
		{
			case 0:
				// is Port A an output?
				if((cntrl & 0x10) == 0)
				{
					portA = value;

					if(writeCallback)
						writeCallback(Port.A, portA, 0xFF);
				}
				break;
			case 1:
				// is Port B an output?
				if((cntrl & 0x02) == 0)
				{
					portB = value;

					if(writeCallback)
						writeCallback(Port.B, portB, 0xFF);
				}
				break;
			case 2:
				// port C Lower DDR (0 = output)
				if((cntrl & 0x01) == 0)
				{
					portC &= 0xF0;
					portC |= value & 0x0F;
				}

				// port C Upper DDR (0 = output)
				if((cntrl & 0x08) == 0)
				{
					portC &= 0x0F;
					portC |= value & 0xF0;
				}

				if(writeCallback && (cntrl & 0x9) != 0x9)
					writeCallback(Port.C, portC, ((cntrl & 0x1) == 0 ? 0x0F : 0) | ((cntrl & 0x8) == 0 ? 0xF0 : 0));
				break;
			case 3:
				if((value & 0x80) != 0) // ordinary control word write
				{
					cntrl = value;

					// when the control word is written, any port programmed as an output is initialised to 0x00

					// port A DDR (0 = output)
					if((cntrl & 0x10) == 0)
					{
						portA = 0;

						if(writeCallback)
							writeCallback(Port.A, portA, 0xFF);
					}

					// port B DDR (0 = output)
					if((cntrl & 0x02) == 0)
					{
						portB = 0;

						if(writeCallback)
							writeCallback(Port.B, portB, 0xFF);
					}

					// port C Lower DDR (0 = output)
					if((cntrl & 0x01) == 0)
						portC &= 0xF0;

					// port C Upper DDR (0 = output)
					if((cntrl & 0x08) == 0) 
						portC &= 0x0F;

					if(writeCallback && (cntrl & 0x9) != 0x9)
						writeCallback(Port.C, portC, ((cntrl & 0x1) == 0 ? 0x0F : 0) | ((cntrl & 0x8) == 0 ? 0xF0 : 0));

					// see if anything other than Mode 0
					if((cntrl & 0x64) != 0)
						assert(false, "Only Mode 0 for I8255 is currently supported.");
				}
				else
				{
					// Port C bit Set / Reset function
					ubyte shift = (value >> 1) & 0x7; // shift amount (the bit to change is determined by the cntrl word bits 1..4)
					ubyte bit = cast(ubyte)(1 << shift);

					ubyte oldC = portC;

					if((value & 0x1) != 0)
						portC |= bit; // set the appropriate bit
					else
						portC &= ~bit; // clear the appropriate bit

					if(portC != oldC && writeCallback && (cntrl & 0x9) != 0x9)
						writeCallback(Port.C, portC, ((cntrl & 0x1) == 0 ? 0x0F : 0) | ((cntrl & 0x8) == 0 ? 0xF0 : 0));
				}
				break;
		}
	}

	uint GetRegisterValue(int reg)
	{
		switch(reg)
		{
			case Register.PortA:
				return portA;
			case Register.PortB:
				return portB;
			case Register.PortC:
				return portC;
			case Register.Control:
				return cntrl;
			default:
				return 0xFF;
		}
	}

	void SetRegisterValue(int reg, uint value)
	{
		switch(reg)
		{
			case Register.PortA:
				portA = cast(ubyte)value;
				break;
			case Register.PortB:
				portB = cast(ubyte)value;
				break;
			case Register.PortC:
				portC = cast(ubyte)value;
				break;
			case Register.Control:
				cntrl = cast(ubyte)value;
				break;
			default:
				break;
		}
	}

private:
	ubyte portA;
	ubyte portB;
	ubyte portC;
	ubyte cntrl;

	WriteDelegate writeCallback;
}

private:

static immutable RegisterInfo[] sRegInfo =
[
	RegisterInfo( "portA", 8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "portB", 8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "portC", 8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "cntrl", 8, RegisterInfo.Flags.ReadOnly, null ),
];

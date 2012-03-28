module demu.systems.segagenesis;

import demu.rommanager.romdatabase;
import demu.rommanager.game;

import demu.machine;
import demu.memmap;

import demu.parts.part;
import demu.parts.cpu.mc68000;
import demu.parts.cpu.z80;
import demu.parts.display.tms9918;
import demu.parts.sound.sn76489;

class SegaGenesis : Machine
{
	this(const(RomInstance)* romDesc, RomDatabase db)
	{
		super(romDesc, db);

		// load the boot rom
		pBIOS = cast(ubyte[])std.file.read("roms/gen/bios/GenesisBIOS.smd");

		// load the ROM image
		pRom = db.LoadRom(romDesc);

		bank = 0;
		scanLine = -1;

		inputPort0 = 0xFF;
		inputPort1 = 0xFF;

		bZ80Reset = true;
		b68kHasBus = false;

		bJapaneseRegion = false;//!_strnicmp(GetLocale(), "jp", 2) ? true : false;

		// configure the 68000 memory map
		callbacks68k[CallbackID68k.Z80].read8 = &Read8_Z80;
		callbacks68k[CallbackID68k.Z80].write8 = &Write8_Z80;
		callbacks68k[CallbackID68k.Z80].read16 = &Read16_Z80;
		callbacks68k[CallbackID68k.Z80].write16 = &Write16_Z80;

		callbacks68k[CallbackID68k.PortCallbacks].read8 = &ReadPorts8;
		callbacks68k[CallbackID68k.PortCallbacks].write8 = &WritePorts8;
		callbacks68k[CallbackID68k.PortCallbacks].read16 = &ReadPorts16;
		callbacks68k[CallbackID68k.PortCallbacks].write16 = &WritePorts16;

		callbacks68k[CallbackID68k.VDPCallbacls].read8 = &ReadVDP8;
		callbacks68k[CallbackID68k.VDPCallbacls].write8 = &WriteVDP8;
		callbacks68k[CallbackID68k.VDPCallbacls].read16 = &ReadVDP16;
		callbacks68k[CallbackID68k.VDPCallbacls].write16 = &WriteVDP16;

		romRange = new MemoryRange("ROM", 0, 0x3FFFFF, 0x3FFFFF, MemFlags.ReadOnly);
		//scdRange.Init("SegaCD", 0x400000, 0x7FFFFF, 0x3FFFFF, MemFlags.ReadWrite);
		//32xRange.Init("32X", 0, 0x800000, 0x9FFFFF, 0x1FFFFF, MemFlags.ReadWrite);

		memMap68k = new MemMap(this, 24, true);
		memMap68k.RegisterMemoryCallbacks(callbacks68k);

		memMap68k.RegisterMemRangeDirect(romRange, pRom.ptr, maskSize(pRom.length));
		memMap68k.MountRangeCallback("Z80", CallbackID68k.Z80, 0xA00000, 0x10000);
		memMap68k.MountRangeCallback("Ports", CallbackID68k.PortCallbacks, 0xA10000, 0xF0000);
		memMap68k.MountRangeCallback("VDP", CallbackID68k.VDPCallbacls, 0xC00000, 0x200000);
		memMap68k.MountRangeDirect("RAM", genRam.ptr, 0xE00000, 0x200000, MemFlags.ReadWrite, 0xFFFF);

		// init the 68000
		mc68k = new MC68000(this, "68000", memMap68k, MC68000.Version.MC68000);
		mc68k.RegisterSymbols(sMappedRegisters);

		AddProcessor(mc68k, 1);

		// init the z80 memory map
		callbacksZ80[CallbackIDZ80.Registers].read8 = &ReadRegs8;
		callbacksZ80[CallbackIDZ80.Registers].write8 = &WriteRegs8;

		callbacksZ80[CallbackIDZ80.MC68k].read8 = &Read8_68k;
		callbacksZ80[CallbackIDZ80.MC68k].write8 = &Write8_68k;
		callbacksZ80[CallbackIDZ80.MC68k].read16 = &Read16_68k;
		callbacksZ80[CallbackIDZ80.MC68k].write16 = &Write16_68k;

		memMapZ80 = new MemMap(this, 16, true);
		memMapZ80.RegisterMemoryCallbacks(callbacksZ80);
		memMapZ80.RegisterIOCallbacks(&ReadIO, &WriteIO);

		memMapZ80.MountRangeDirect("RAM", z80Ram.ptr, 0x0000, 0x4000, MemFlags.ReadWrite, 0x1FFF);
		memMapZ80.MountRangeCallback("REGS", CallbackIDZ80.Registers, 0x4000, 0x4000);
		memMapZ80.MountRangeCallback("68K", CallbackIDZ80.MC68k, 0x8000, 0x8000);

		// init the Z80
		z80 = new Z80(this, "Z80", memMapZ80);
		z80.SetReady(false);
		AddProcessor(z80, 2);

		vdp = new TMS9918(this, "VDP", TMS9918.Version.YM7101, memMap68k);

		psg = new  SN76489(this, "PSG", SN76489.Version.SN76489_SMS, 3.58f);

		enum int cyclesPerFrame = 7680000 / 60;
		enum int cyclesPerScanline = cyclesPerFrame / 262;

		AddCountdownTimer(cyclesPerScanline, 0, &HBlank);
		AddCountdownTimer(cyclesPerScanline, 54, &DrawLine); // give the machine some hblank time before rendering the line

		// setup the PSG
		samplesPerFrame = psg.BeginFrame();
		AddCountdownTimer(psg.ClocksPerSample * 2, 0, &PSGClock);

		Reset();

//		EnableThreadedExecution(true);

		mc68k.LogExecution(LogTarget.Console, true);
		//z80.LogExecution(true);

		//mc68k.SetDefaultLogHandler(Processor::Log_Console);
	}

	void Reset()
	{
		// reset the system
		mc68k.Reset();
		z80.SetReady(false);
	}

	void Update()
	{
		inputPort0 = 0xFF;
		inputPort1 = 0xFF;

		// read input
/+
		if(const MappedInputs* pMappedInputs = GetMappedInputs())
		{
			inputPort0 ^= pMappedInputs->GetInput("UP", 0) ? 0x01 : 0;
			inputPort0 ^= pMappedInputs->GetInput("DOWN", 0) ? 0x02 : 0;
			inputPort0 ^= pMappedInputs->GetInput("LEFT", 0) ? 0x04 : 0;
			inputPort0 ^= pMappedInputs->GetInput("RIGHT", 0) ? 0x08 : 0;
			inputPort0 ^= pMappedInputs->GetInput("A", 0) ? 0x10 : 0;
			inputPort0 ^= pMappedInputs->GetInput("B", 0) ? 0x20 : 0;

			inputPort0 ^= pMappedInputs->GetInput("UP", 1) ? 0x40 : 0;
			inputPort0 ^= pMappedInputs->GetInput("DOWN", 1) ? 0x80 : 0;
			inputPort1 ^= pMappedInputs->GetInput("LEFT", 1) ? 0x01 : 0;
			inputPort1 ^= pMappedInputs->GetInput("RIGHT", 1) ? 0x02 : 0;
			inputPort1 ^= pMappedInputs->GetInput("A", 1) ? 0x04 : 0;
			inputPort1 ^= pMappedInputs->GetInput("B", 1) ? 0x08 : 0;

			inputPort1 ^= pMappedInputs->GetInput("RESET") ? 0x10 : 0;

			if(pMappedInputs->GetInput("PAUSE"))
			{
				// PAUSE button generates NMI
				z80.TriggerNMI();
			}
		}
+/
	}

protected:
	enum CallbackID68k
	{
		Z80 = 0,
		PortCallbacks,
		VDPCallbacls,
		Max68k
	};

	enum CallbackIDZ80
	{
		Registers = 0,
		MC68k,
		MaxZ80
	};

	// system components
	MC68000 mc68k;
	Z80 z80;
	TMS9918 vdp;
	SN76489 psg;

	uint bank;

	ubyte[] pBIOS;
	ubyte[] pRom;

	// machine state variables
	int scanLine;

	ubyte inputPort0;
	ubyte inputPort1;

	bool bJapaneseRegion;

	bool bZ80Reset;
	bool b68kHasBus;

	int samplesPerFrame;

	MemoryCallbacks[CallbackID68k.Max68k] callbacks68k;
	MemoryRange romRange;
	MemMap memMap68k;

	MemoryCallbacks[CallbackIDZ80.MaxZ80] callbacksZ80;
	MemMap memMapZ80;

	int __manually_padd_for_alignment__;
	align(16) ubyte[0x10000] genRam;
	align(16) ubyte[0x2000] z80Ram;

	// private methods
	bool HBlank(int timerIndex, long tick)
	{
		++scanLine;
		if(scanLine == 262)
			scanLine = 0;

		// z80 irq signal should only remain active for 1 line
		z80.SignalIRQ(false);

		bool bDidSignalLineInterrupt = false;
		if(scanLine < 224)
		{
			if(vdp.BeginScanline())
			{
				mc68k.SignalIRQ(4);
				bDidSignalLineInterrupt = true;
			}
		}

		if(scanLine == 224)
		{
			psg.FinishFrame(samplesPerFrame);
			samplesPerFrame = psg.BeginFrame();

			if(vdp.BeginFrame() && !bDidSignalLineInterrupt)
				mc68k.SignalIRQ(6);
			z80.SignalIRQ(true);

			// draw the frame
			vdp.DrawFrame();

			return true;
		}

		return false;
	}

	bool DrawLine(int timerIndex, long tick)
	{
		// we'll render out a line here
		if(scanLine >= 0)
			vdp.DrawLine();

		return false;
	}

	bool PSGClock(int timerIndex, long tick)
	{
		if(samplesPerFrame)
		{
//			psg.GenerateSamples(1);
			--samplesPerFrame;
		}
		return false;
	}

	ubyte ReadPorts8(uint address)
	{
		ushort value = ReadPorts16(address & ~1);
		return cast(ubyte)((address & 1) ? value & 0xFF : value >> 8);
	}

	void WritePorts8(uint address, ubyte value)
	{
		ushort v = (address & 1) == 0 ? value << 8 : value;
		WritePorts16(address & 0xFFFFFE, v);
	}

	ushort ReadPorts16(uint address)
	{
		address &= 0xFFFF;

		switch(address >> 12)
		{
			case 0x0:
				switch((address >> 1) & 0xF)
				{
					case 0x0:
						// Version register (read-only word-long)
						return 0xA0;
					case 0x1:
						// Controller 1 data
						return 0x7F;
					case 0x2:
						// Controller 2 data
						return 0x7F;
					case 0x3:
						// Expansion port data
						return 0x7F;
					case 0x4:
						// Controller 1 control
						return 0x00;
					case 0x5:
						// Controller 2 control
						return 0x00;
					case 0x6:
						// Expansion port control
						return 0x00;
					case 0x7:
						// Port A serial transmit
						return 0xFF;
					case 0x8:
						// Port A serial receive
						return 0x00;
					case 0x9:
						// Port A serial control
						return 0x00;
					case 0xA:
						// Port B serial transmit
						return 0xFF;
					case 0xB:
						// Port B serial receive
						return 0x00;
					case 0xC:
						// Port B serial control
						return 0x00;
					case 0xD:
						// Port C serial transmit
						return 0xFF;
					case 0xE:
						// Port C serial receive
						return 0x00;
					case 0xF:
						// Port C serial control
						return 0x00;
					default:
						break;
				}
				break;
			case 0x1:
				switch((address >> 8) & 0xF)
				{
					case 0x0:
						// Memory mode register
						break;
					case 0x1:
						// Z80 bus request
						return b68kHasBus && !bZ80Reset ? 0 : 0x100;
					case 0x2:
						// Z80 reset
						return bZ80Reset ? 0 : 0x100;
					default:
						break;
				}
				break;
			case 0x4:
				if(address == 0x4000)
				{
					// TMSS register
				}
				break;
			default:
				break;
		}

		return 0xFFFF;
	}

	void WritePorts16(uint address, ushort value)
	{
		address &= 0xFFFF;

		switch(address >> 12)
		{
			case 0x0:
				switch((address >> 1) & 0xF)
				{
					case 0x1:
						// Controller 1 data
						break;
					case 0x2:
						// Controller 2 data
						break;
					case 0x3:
						// Expansion port data
						break;
					case 0x4:
						// Controller 1 control
						break;
					case 0x5:
						// Controller 2 control
						break;
					case 0x6:
						// Expansion port control
						break;
					case 0x7:
						// Controller 1 serial transmit
						break;
					case 0x8:
						// Controller 1 serial receive
						break;
					case 0x9:
						// Controller 1 serial control
						break;
					case 0xA:
						// Controller 2 serial transmit
						break;
					case 0xB:
						// Controller 2 serial receive
						break;
					case 0xC:
						// Controller 2 serial control
						break;
					case 0xD:
						// Expansion port serial transmit
						break;
					case 0xE:
						// Expansion port serial receive
						break;
					case 0xF:
						// Expansion port serial control
						break;
					default:
						break;
				}
				break;
			case 0x1:
				switch((address >> 8) & 0xF)
				{
					case 0x0:
						// Memory mode register
						break;
					case 0x1:
						// Z80 bus request
						if(value & 0x100)
						{
							// request Z80 bus
							z80.SetReady(false);
							b68kHasBus = true;
						}
						else
						{
							// release Z80 bus
							if(!bZ80Reset)
								z80.SetReady(true);
							b68kHasBus = false;
						}
						break;
					case 0x2:
						// Z80 reset
						if(value & 0x100)
						{
							// end reset sequence
							if(!b68kHasBus)
								z80.SetReady(true);
							z80.Reset();
							bZ80Reset = false;
						}
						else
						{
							// begin reset sequence
							z80.SetReady(false);
							bZ80Reset = true;
						}
						break;
					default:
						break;
				}
				break;
			case 0x4:
				if(address == 0x4000)
				{
					// TMSS register
				}
				break;
			default:
				break;
		}
	}

	ubyte ReadVDP8(uint address)
	{
		ushort value = ReadVDP16(address & ~1);
		return (address & 1) ? cast(ubyte)(value & 0xFF) : cast(ubyte)(value >> 8);
	}

	void WriteVDP8(uint address, ubyte value)
	{
		WriteVDP16(address & ~1, cast(ushort)value | cast(ushort)(value << 8));
	}

	ushort ReadVDP16(uint address)
	{
		address &= 0xF;

		switch(address)
		{
			case 0x0:
			case 0x2:
				// VDP data
				return vdp.Read16(0);
			case 0x4:
			case 0x6:
				// VDP status
				return vdp.Read16(1);
			case 0x8:
				// VDP HV counter
				break;
			default:
				break;
		}

		return 0xFFFF;
	}

	void WriteVDP16(uint address, ushort value)
	{
		address &= 0x1F;

		switch(address)
		{
			case 0x0:
			case 0x2:
				// VDP data
				vdp.Write16(0, value);
			case 0x4:
			case 0x6:
				// VDP control
				vdp.Write16(1, value);
				break;
			case 0x10:
			case 0x12:
			case 0x14:
			case 0x16:
				// PSG write
				psg.Write(cast(ubyte)(value & 0xFF));
				break;
			default:
				break;
		}
	}

	// read/write the Z80 address space from the 68000
	ubyte Read8_Z80(uint address)
	{
		if(!b68kHasBus)
			return 0x00;
		return memMapZ80.Read8(address & 0x7FFF);
	}
	void Write8_Z80(uint address, ubyte value)
	{
		if(b68kHasBus)
			memMapZ80.Write8(address & 0x7FFF, value);
	}
	ushort Read16_Z80(uint address)
	{
		if(!b68kHasBus)
			return 0x00;
		ubyte value = memMapZ80.Read8(address & 0x7FFF);
		return (cast(ushort)value << 8) | cast(ushort)value;
	}
	void Write16_Z80(uint address, ushort value)
	{
		if(b68kHasBus)
			memMapZ80.Write8(address & 0x7FFF, cast(ubyte)(value >> 8));
	}

	// read/write Z80 registers in the range $2000-$7FFF
	ubyte ReadRegs8(uint address)
	{
		switch(address >> 8)
		{
			case 0x40:
				switch(address & 3)
				{
					case 0x0:
						// YM2612 A0
						break;
					case 0x1:
						// YM2612 D0
						break;
					case 0x2:
						// YM2612 A1
						break;
					case 0x3:
						// YM2612 D1
						break;
					default:
						break;
				}
				break;
			case 0x7F:
				// VDP space
				return ReadVDP8(address & 0xFF);
			default:
				break;
		}
		return 0xFF;
	}
	void WriteRegs8(uint address, ubyte value)
	{
		switch(address >> 8)
		{
			case 0x40:
				switch(address & 0x3)
				{
					case 0x0:
						// YM2612 A0
						break;
					case 0x1:
						// YM2612 D0
						break;
					case 0x2:
						// YM2612 A1
						break;
					case 0x3:
						// YM2612 D1
						break;
					default:
						break;
				}
				break;
			case 0x60:
				// BANK REGISTER
				// shift the lsb into the top of the bank register
				bank |= value << 24;
				bank = (bank >> 1) & 0xFF8000;
				break;
			case 0x7F:
				// VDP space
				WriteVDP8(address & 0xFF, value);
				break;
			default:
				break;
		}
	}

	// read/write the 68k address space from the Z80
	ubyte Read8_68k(uint address)
	{
		return memMap68k.Read8((address & 0x7FFF) | bank);
	}
	void Write8_68k(uint address, ubyte value)
	{
		memMap68k.Write8((address & 0x7FFF) | bank, value);
	}
	ushort Read16_68k(uint address)
	{
		return memMap68k.Read16_LE((address & 0x7FFF) | bank);
	}
	void Write16_68k(uint address, ushort value)
	{
		memMap68k.Write16_LE((address & 0x7FFF) | bank, value);
	}

	// Z80 IO Space
	ubyte ReadIO(uint address)
	{
		// all IO ports return $FF
		return 0xFF;
	}
	void WriteIO(uint address, ubyte value)
	{
		// these do nothing
	}
}

private:

static AddressInfo[] sMappedRegisters =
[
	// mapped
	AddressInfo( 0xA10000, "VERSION" ),
	AddressInfo( 0xA10002, "DATA_A" ),
	AddressInfo( 0xA10004, "DATA_B" ),
	AddressInfo( 0xA10006, "DATA_C" ),
	AddressInfo( 0xA10002, "CTRL_A" ),
	AddressInfo( 0xA10004, "CTRL_B" ),
	AddressInfo( 0xA10006, "CTRL_C" ),

	AddressInfo( 0xA11000, "MEMORY_MODE" ),
	AddressInfo( 0xA11100, "Z80_BUSREQ" ),
	AddressInfo( 0xA11200, "Z80_RESET" ),

	AddressInfo( 0xC00000, "VDP_DATA0" ),
	AddressInfo( 0xC00002, "VDP_DATA1" ),
	AddressInfo( 0xC00004, "VDP_CONTROL0" ),
	AddressInfo( 0xC00006, "VDP_CONTROL1" ),
	AddressInfo( 0xC00008, "HV_COUNTER" ),
	AddressInfo( 0xC0000A, "HV_COUNTER" ),
	AddressInfo( 0xC0000C, "HV_COUNTER" ),
	AddressInfo( 0xC0000E, "HV_COUNTER" ),
	AddressInfo( 0xC00010, "PSG" ),
	AddressInfo( 0xC00012, "PSG" ),
	AddressInfo( 0xC00014, "PSG" ),
	AddressInfo( 0xC00016, "PSG" ),
];

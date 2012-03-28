module demu.systems.segamastersystem;

import demu.rommanager.romdatabase;
import demu.rommanager.game;

import demu.machine;
import demu.memmap;

import demu.parts.part;
import demu.parts.cpu.z80;
import demu.parts.display.tms9918;
import demu.parts.sound.sn76489;

class SegaMasterSystem : Machine
{
	enum Version
	{
		SG_1000,
		SG_1000II,
		SC_3000,
		SC_3000H,
		SegaMarkIII,
		SegaMasterSystem,
		GameGear
	}

	this(const(RomInstance)* romDesc, RomDatabase db)
	{
		super(romDesc, db);

		// get system version from rom instance
		Version revision = Version.SegaMasterSystem;

		this.revision = revision;

		// load the ROM image
		rom = db.LoadRom(romDesc);

		if(revision < Version.SegaMarkIII)
		{
			ram = new ubyte[2*1024];
			cartRam = new ubyte[32*1024];
		}
		else
		{

			bios = cast(ubyte[])std.file.read("roms/sms/bios/SMSBIOS_MK3.sms");

			ram = new ubyte[8*1024];
			cartRam = new ubyte[32*1024];
		}

		page[0] = 0;
		page[1] = 0;
		page[2] = 1;
		page[3] = 0;

		bDisableCartridgeSlot = bios ? true : false; // allow the system to boot from the bios if present
		bDisableBIOS = bios ? false : true; // enable the bios if it was loaded
		bDisableIOChip = false;
		bDisableRAM = false;
		bDisableCardSlot = true;
		bDisableExpansionSlot = true;
		ram[0] = 0xAB;

		IOControl = 0xFF;
		inputPort0 = 0xFF;
		inputPort1 = 0xFF;

		bJapaneseRegion = false;// !_strnicmp(GetLocale(), "jp", 2) ? true : false;

		// init the MemMap
		memMap = new MemMap(this, 16);

		if(revision < Version.SegaMarkIII)
		{
			memMap.MountRangeDirect("Rom", rom.ptr, 0x0000, 0x8000, MemFlags.ReadOnly, maskSize(rom.length));
			memMap.MountRangeDirect("Work Ram", cartRam.ptr, 0x8000, 0x4000, MemFlags.ReadWrite);
			memMap.MountRangeDirect("Ram", ram.ptr, 0xC000, 0x4000, MemFlags.ReadWrite, 0x7FF);
		}
		else
		{
			callbacks[Callbacks.BankRegs].read8 = &ReadBankRegs;
			callbacks[Callbacks.BankRegs].write8 = &WriteBankRegs;

			memMap.RegisterMemoryCallbacks(callbacks);
			memMap.RegisterIOCallbacks(&IORead, &IOWrite);

			memMap.MountRangeDirect("Page0", rom.ptr + page[1]*0x4000, 0x0000, 0x4000, MemFlags.ReadOnly);
			memMap.MountRangeDirect("Page1", rom.ptr + page[2]*0x4000, 0x4000, 0x4000, MemFlags.ReadOnly);
			memMap.MountRangeDirect("Page2", rom.ptr + page[3]*0x4000, 0x8000, 0x4000, MemFlags.ReadWrite);
			memMap.MountRangeDirect("Ram", ram.ptr, 0xC000, 0x3F00, MemFlags.ReadWrite, 0x1FFF);
			memMap.MountRangeCallback("PageRegisters", Callbacks.BankRegs, 0xFF00, 0x100);

			// mount the bios across the first 2 pages at boot
			if(bios)
				memMap.UpdateRangeDirect(0x0000, 0x8000, bios.ptr, 0x1FFF);
		}

		// init the CPU
		cpu = new Z80(this, "Z80", memMap);
		cpu.IntAckCallback = &ReleaseIRQ;
		cpu.RegisterSymbols(sMappedRegisters);
		cpu.RegisterPortSymbols(sMappedPorts);
		AddProcessor(cpu, 1);

		if(revision < Version.SegaMarkIII)
		{
			vdp = new TMS9918(this, "VDP", TMS9918.Version.TMS9928A);
			psg = new SN76489(this, "PSG", SN76489.Version.SN76489, 4.194304f);
		}
		else
		{
			vdp = new TMS9918(this, "VDP", TMS9918.Version.SegaVDP);
			psg = new SN76489(this, "PSG", SN76489.Version.SN76489_SMS, 4.194304f);
		}

		AddCountdownTimer(59659 / 262, 0, &HBlank);
		AddCountdownTimer(59659 / 262, 54, &DrawLine); // give the machine some hblank time before rendering the line

		// setup the PSG
		samplesPerFrame = psg.BeginFrame();
		AddCountdownTimer(psg.ClocksPerSample, 0, &PSGClock);

		Reset();

//		EnableThreadedExecution(true);
	}

	void Reset()
	{
		// reset the cpu
		cpu.Reset();
	}

	void Update()
	{
		inputPort0 = 0xFF;
		inputPort1 = 0xFF;

		// read input
/*
		if(const MappedInputs* pMappedInputs = GetMappedInputs())
		{
			inputPort0 ^= pMappedInputs.GetInput("UP", 0) ? 0x01 : 0;
			inputPort0 ^= pMappedInputs.GetInput("DOWN", 0) ? 0x02 : 0;
			inputPort0 ^= pMappedInputs.GetInput("LEFT", 0) ? 0x04 : 0;
			inputPort0 ^= pMappedInputs.GetInput("RIGHT", 0) ? 0x08 : 0;
			inputPort0 ^= pMappedInputs.GetInput("A", 0) ? 0x10 : 0;
			inputPort0 ^= pMappedInputs.GetInput("B", 0) ? 0x20 : 0;

			inputPort0 ^= pMappedInputs.GetInput("UP", 1) ? 0x40 : 0;
			inputPort0 ^= pMappedInputs.GetInput("DOWN", 1) ? 0x80 : 0;
			inputPort1 ^= pMappedInputs.GetInput("LEFT", 1) ? 0x01 : 0;
			inputPort1 ^= pMappedInputs.GetInput("RIGHT", 1) ? 0x02 : 0;
			inputPort1 ^= pMappedInputs.GetInput("A", 1) ? 0x04 : 0;
			inputPort1 ^= pMappedInputs.GetInput("B", 1) ? 0x08 : 0;

			inputPort1 ^= pMappedInputs.GetInput("RESET") ? 0x10 : 0;

			if(pMappedInputs.GetInput("PAUSE"))
			{
				// PAUSE button generates NMI
				cpu.TriggerNMI();
			}
		}
*/
	}

protected:
	enum Callbacks
	{
		BankRegs = 0,
		Count
	};

	Version revision;

	// system components
	Z80 cpu;
	TMS9918 vdp;
	SN76489 psg;

	MemMap memMap;
	MemoryCallbacks[Callbacks.Count] callbacks;

	ubyte[] bios;
	ubyte[] rom;

	ubyte[] ram;
	ubyte[] cartRam;

	ubyte[4] page;

	// machine state variables
	int scanLine;

	ubyte IOControl;
	ubyte inputPort0;
	ubyte inputPort1;

	bool bDisableIOChip;
	bool bDisableBIOS;
	bool bDisableRAM;
	bool bDisableCardSlot;
	bool bDisableCartridgeSlot;
	bool bDisableExpansionSlot;

	bool bJapaneseRegion;

	int samplesPerFrame;

	ubyte ReadBankRegs(uint address)
	{
		return ram[address & 0x1FFF];
	}

	void WriteBankRegs(uint address, ubyte value)
	{
		if(!bDisableRAM)
		{
			// 8k main ram
			ram[address & 0x1FFF] = value;
		}

		if(address >= 0xFFF8)
		{
			// paging registers
			final switch(address - 0xFFF8)
			{
				case 0:
				case 1:
				case 2:
				case 3:
					// 3d glasses control
					assert(false, "3D glasses not supported");
					break;
				case 4:
					page[0] = value;
					if(value & 0x8)
						memMap.UpdateRangeDirect(0x8000, 0xC000, cartRam.ptr + ((value & 0x4) ? 0x4000 : 0x0000));
					else
						memMap.UpdateRangeDirect(0x8000, 0xC000, rom.ptr + ((page[3]*0x4000) & (rom.length - 1)));
					break;
				case 5:
					page[1] = value;
					memMap.UpdateRangeDirect(0x0400, 0x4000, rom.ptr + ((value*0x4000) & (rom.length - 1)) + 0x400);
					break;
				case 6:
					page[2] = value;
					memMap.UpdateRangeDirect(0x4000, 0x8000, rom.ptr + ((value*0x4000) & (rom.length - 1)));
					break;
				case 7:
					page[3] = value;
					if(!(page[0] & 0x8))
						memMap.UpdateRangeDirect(0x8000, 0xC000, rom.ptr + ((value*0x4000) & (rom.length - 1)));
					break;
			}
		}
	}

	ubyte IORead(uint address)
	{
		address &= 0xC1;

		switch(address)
		{
			case 0x40:
				return cast(ubyte)(scanLine < 0 ? 0 : scanLine); // v counter
			case 0x41:
				return cast(ubyte)(cpu.CycleCount % (59659 / 262)); // h counter
			case 0x80:
			case 0x81:
				return vdp.Read8(address);
			case 0xC0:
				return inputPort0;
			case 0xC1:
				{
					ubyte port1 = inputPort1;

					if(!(IOControl & 0x02))
						port1 &= (bJapaneseRegion ? 0 : ((IOControl << 1) & 0x40)) | 0xBF;
					if(!(IOControl & 0x08))
						port1 &= (bJapaneseRegion ? 0 : (IOControl & 0x80)) | 0x7F;

					return port1;
				}
			case 0x00:
			case 0x01:
			default:
				break;
		}

		return 0xFF;
	}

	void IOWrite(uint address, ubyte value)
	{
		address &= 0xC1;

		switch(address)
		{
			case 0x00:
				// memory control register
				bDisableIOChip = !!(value & 0x04);
				bDisableBIOS = !!(value & 0x08);
				bDisableRAM = !!(value & 0x10);
				bDisableCardSlot = !!(value & 0x20);
				bDisableCartridgeSlot = !!(value & 0x40);
				bDisableExpansionSlot = !!(value & 0x80);

				// update the memmap accordingly...
				if(!bDisableCartridgeSlot)
				{
					// first 1k always points at the start of rom
					memMap.UpdateRangeDirect(0x0000, 0x0400, rom.ptr);
					// map page 0 (starts at 0x400)
					memMap.UpdateRangeDirect(0x0400, 0x4000, rom.ptr + ((page[1]*0x4000) & (rom.length - 1)) + 0x400);
					// map page 1
					memMap.UpdateRangeDirect(0x4000, 0x8000, rom.ptr + ((page[2]*0x4000) & (rom.length - 1)));
					// page 2 may be switched between rom or cart ram
					if(page[0] & 0x8)
						memMap.UpdateRangeDirect(0x8000, 0xC000, cartRam.ptr + ((page[0] & 0x4) ? 0x4000 : 0x0000));
					else
						memMap.UpdateRangeDirect(0x8000, 0xC000, rom.ptr + ((page[3]*0x4000) & (rom.length - 1)));
				}
				else if(!bDisableBIOS)
				{
					// map 0x0000-0x8000 to bios
					memMap.UpdateRangeDirect(0x0000, 0x8000, bios.ptr);
					// unmap 0x8000-0xC000
					memMap.UpdateRangeDirect(0x8000, 0xC000, null);
				}
				else
				{
					// unmap 0x0000-0xC000
					memMap.UpdateRangeDirect(0x0000, 0xC000, null);
				}
				break;
			case 0x01:
				// I/O control register
				IOControl = value;
				break;
			case 0x40:
			case 0x41:
				// PSG
				psg.Write(value);
				break;
			case 0x80:
			case 0x81:
				// VDP ports
				vdp.Write8(address, value);
				break;
			case 0xC0:
			case 0xC1:
			default:
				break;
		}
	}

	bool HBlank(int timerIndex, long tick)
	{
		++scanLine;

		if(scanLine >= 0)
		{
			if(vdp.BeginScanline())
				cpu.SignalIRQ(1);
		}

		if(scanLine == 262 - 33)
		{
			psg.FinishFrame(samplesPerFrame);
			samplesPerFrame = psg.BeginFrame();

			if(vdp.BeginFrame())
				cpu.SignalIRQ(1);

			scanLine = -33; // give the system some vblank time...

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
}

private:

static immutable AddressInfo[] sMappedRegisters =
[
	// mapped
	AddressInfo( 0xFFFC, "RAM_SELECT", null, SymbolType.CodeLabel ),
	AddressInfo( 0xFFFD, "PAGE_0", null, SymbolType.CodeLabel ),
	AddressInfo( 0xFFFE, "PAGE_1", null, SymbolType.CodeLabel ),
	AddressInfo( 0xFFFF, "PAGE_2", null, SymbolType.CodeLabel )
];

static immutable AddressInfo[] sMappedPorts =
[
	// ports
	AddressInfo( 0x00, "GG_PORT_0" ),
	AddressInfo( 0x01, "GG_PORT_1" ),
	AddressInfo( 0x02, "GG_PORT_2" ),
	AddressInfo( 0x03, "GG_PORT_3" ),
	AddressInfo( 0x04, "GG_PORT_4" ),
	AddressInfo( 0x05, "GG_PORT_5" ),
	AddressInfo( 0x06, "GG_PORT_6" ),
	AddressInfo( 0x07, "GG_PORT_7" ),
	AddressInfo( 0x3E, "MEM_CONTROL" ),
	AddressInfo( 0x3F, "IO_PORT_CONTROL" ),
	AddressInfo( 0x7E, "V_COUNTER", "PSG" ),
	AddressInfo( 0x7F, "H_COUNTER", "PSG" ),
	AddressInfo( 0xBD, "VDP_STATUS", "VDP_CONTROL" ),
	AddressInfo( 0xBE, "VDP_DATA", "VDP_DATA" ),
	AddressInfo( 0xBF, "VDP_STATUS", "VDP_CONTROL" ),
	AddressInfo( 0xC0, "PORT_A_B" ),
	AddressInfo( 0xC1, "PORT_B_MISC" ),
	AddressInfo( 0xDC, "PORT_A_B" ),
	AddressInfo( 0xDD, "PORT_B_MISC" ),
	AddressInfo( 0xDE, "SG_PORT_A" ),
	AddressInfo( 0xDF, "SG_PORT_B" )
];

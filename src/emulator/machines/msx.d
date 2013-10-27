module demu.emulator.systems.msx;

import demu.rommanager.romdatabase;
import demu.rommanager.game;

import demu.emulator.machine;
import demu.emulator.memmap;

import demu.emulator.parts.part;
import demu.emulator.parts.cpu.z80;
import demu.emulator.parts.display.tms9918;
import demu.emulator.parts.sound.sn76489;

class MSX : Machine
{
	this(const(RomInstance)* romDesc, RomDatabase db)
	{
		super(romDesc, db);

		// load the ROM image
		rom = db.LoadRom(romDesc);

		ram = new ubyte[0x2000];

		// init the MemMap
		memMap = new MemMap(this, 16);
		memMap.RegisterIOCallbacks(&IORead, &IOWrite);
//		bios = memMap.MountRomImageDirect("roms/msx/bios/MSX.rom", 0x0000);
//		memMap.MountRangeDirect("RAM", ram.ptr, 0x6000, 0x2000, MemFlags.ReadWrite, 0x3FF);
//		memMap.MountRangeDirect("ROM", rom.ptr, 0x8000, 0x8000, MemFlags.ReadOnly, 0xFFFF); // do we want an address mask to mirror small roms across the rom space?

		// init the CPU
		cpu = new Z80(this, "Z80", memMap);
		cpu.IntAckCallback = &ReleaseIRQ;
		//cpu.RegisterSymbols(sMappedRegisters);
		//cpu.RegisterPortSymbols(sMappedPorts);
		AddProcessor(cpu, 1);

		vdp = new TMS9918(this, "VDP", TMS9918.Version.TMS9918);

		// MSX uses an AY3
//		psg = new SN76489(this, "PSG", 4.194304f);
//		psg.SetFilterLevel(SN76489.Filter.FILTER_1);

		// I8255 PIA

		AddCountdownTimer(59659, 59659, &VBlank);
		AddCountdownTimer(59659 / 262, 0, &HBlank);
		AddCountdownTimer(59659 / 262, 54, &DrawLine); // give the machine some hblank time before rendering the line

		// setup the PSG
		samplesPerFrame = psg.BeginFrame();
		AddCountdownTimer(psg.ClocksPerSample, 0, &PSGClock);

		Reset();

		//EnableThreadedExecution(true);
	}

	override void Reset()
	{
		// reset the cpu
		cpu.Reset();
	}

	override void Update()
	{
	}

protected:
	// system components
	Z80 cpu;
	TMS9918 vdp;
	SN76489 psg;

	MemMap memMap;

	ubyte[] bios;
	ubyte[] rom;

	ubyte[] ram;

	// machine state variables
	int scanLine;

	int samplesPerFrame;

	ubyte IORead(uint address)
	{
		address &= 0xFF;

		switch(address >> 5)
		{
			case 5:
				// video
				return vdp.Read8(address);
			case 7:
				// controllers
				if(address & 2)
					return 0xFF; // controller 1
				else
					return 0xFF; // controller 2
			default:
				break;
		}

		return 0xFF;
	}

	void IOWrite(uint address, ubyte value)
	{
		address &= 0xFF;

		switch(address >> 5)
		{
			case 4:
				// CTRL_EN_2
				break;
			case 5:
				// video
				vdp.Write8(address, value);
				break;
			case 6:
				// CTRL_EN_1
				break;
			case 7:
				// sound
				psg.Write(value);
				break;
			default:
				break;
		}
	}

	bool VBlank(int timerIndex, long tick)
	{
		psg.FinishFrame(samplesPerFrame);
		samplesPerFrame = psg.BeginFrame();

		if(vdp.BeginFrame())
			cpu.TriggerNMI();
		scanLine = -33; // give the system some vblank time...

		// draw the frame
		vdp.DrawFrame();

		return true;
	}

	bool HBlank(int timerIndex, long tick)
	{
		++scanLine;

		if(scanLine >= 0)
		{
			if(vdp.BeginScanline())
				cpu.SignalIRQ(true);
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
	AddressInfo( 0xFFFC, "RAM_SELECT", null, SymbolType.CodeLabel )
];

static immutable AddressInfo[] sMappedPorts =
[
	// ports
	AddressInfo( 0x00, "GG_PORT_0" )
];

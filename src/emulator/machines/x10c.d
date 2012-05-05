module demu.emulator.systems.x10c;

import demu.rommanager.romdatabase;
import demu.rommanager.game;

import demu.emulator.machine;
import demu.emulator.memmap;
import demu.emulator.display;

import demu.emulator.parts.part;
import demu.emulator.parts.cpu.dcpu16;

class x10c : Machine
{
	this(const(RomInstance)* romDesc, RomDatabase db)
	{
		super(romDesc, db);

		// load the ROM image
//		rom = db.LoadRom(romDesc);

		ushort[] program =
		[
			0x7c01, 0x0030, 0x7de1, 0x1000, 0x0020, 0x7803, 0x1000, 0xc00d,
			0x7dc1, 0x001a, 0xa861, 0x7c01, 0x2000, 0x2161, 0x2000, 0x8463,
			0x806d, 0x7dc1, 0x000d, 0x9031, 0x7c10, 0x0018, 0x7dc1, 0x001a,
			0x9037, 0x61c1, 0x7dc1
		];

		ram = new ushort[0x10000];

		ram[0..program.length] = program[];

		callbacks[Callbacks.Memory].read16 = &Read;
		callbacks[Callbacks.Memory].write16 = &Write;

		// init the MemMap
		memMap = new MemMap(this, 16);
		memMap.RegisterMemoryCallbacks(callbacks);
		memMap.MountRangeCallback("RAM", Callbacks.Memory, 0x0000, 0x8000);
		memMap.MountRangeCallback("DISPLAY", Callbacks.Memory, 0x8000, 0x1000);
		memMap.MountRangeCallback("MEMORY", Callbacks.Memory, 0x9000, 0x100);
		memMap.MountRangeCallback("STACK", Callbacks.Memory, 0x9100, 0x6F00);

		// init the CPU
		cpu = new DCPU_16(this, "DCPU-16", memMap);
		AddProcessor(cpu, 1);

		AddCountdownTimer(100000/60, 0, &VBlank);

		// configure the display
		DisplayProperties desc;
		desc.size = DisplayDimensions((32 + 4) * 4, (12 + 2) * 8);
		desc.rotation = DisplayRotation.None;
		desc.aspectRatio = 4.0f/3.0f;
		Display display = CreateDisplay(desc);

		// create a render layer
		LayerDesc layerDesc;
		layerDesc.size = desc.size;
		layerDesc.format = Display.Format.D8_RGB24;
		layerDesc.mode = LayerPresentMode.Flip;
		layerDesc.numPaletteEntries = 16;
		layer = &display.ConfigureLayer(0, layerDesc);
		layer.SetPalette(palette);

		Reset();

		//EnableThreadedExecution(true);
	}

	void Reset()
	{
		// reset the cpu
		cpu.Reset();
	}

	void Update()
	{
		// poke the keys into 0x9000-900F + 0x9010
	}

protected:
	enum Callbacks
	{
		Memory = 0
	}

	DCPU_16 cpu;

	ushort[] ram;

	Display.Layer* layer;

	MemMap memMap;
	MemoryCallbacks[Callbacks.max + 1] callbacks;

	ushort Read(uint address)
	{
		return ram[address];
	}

	void Write(uint address, ushort value)
	{
		ram[address] = value;
	}

	bool VBlank(int timerIndex, long tick)
	{
		RenderFrame();
		return true;
	}

	void RenderFrame()
	{
		// draw the frame
		uint[] drawBuffer = cast(uint[])layer.DrawBuffer;

		ushort[] tileMap = ram[0x8000 .. 0x8180];
		ushort[] charMap = ram[0x8180 .. 0x8280];

		// get dimensions
		int width = layer.Descriptor.size.width;
		int height = layer.Descriptor.size.height;

		// fill the borders
		uint bgColour = palette[ram[0x8280]];

		drawBuffer[0 .. 8*width + 8] = bgColour;
		drawBuffer[(height - 8)*width .. height*width] = bgColour;

		uint* border = &drawBuffer[8*width + width - 8];
		foreach(i; 0..12*8)
		{
			border[0..16] = bgColour;
			border += width;
		}

		// trim the border off the frame buffer
		drawBuffer = drawBuffer[8*width + 8 .. (height - 8)*width + 8];

		foreach(y; 0..12)
		{
			foreach(x; 0..32)
			{
				int offset = y*32 + x;

				// get the tile
				ushort tile = tileMap[offset];

				// get the tile bitmap
				int tileBitmap = (tile & 0x7F) * 2;
				uint bitmap = charMap[tileBitmap] << 16;
				bitmap |= charMap[tileBitmap + 1];

				// get fg/bg colours
				uint[2] colour = [palette[(tile >> 8) & 0xF], palette[(tile >> 12) & 0xF]];

				// get tile buffer
				uint* tileBuffer = &drawBuffer[y*8*width + x*4];

				// render tile
				foreach(p; 0..32)
					tileBuffer[(p & 0x7)*width + (p >> 3)] = colour[(bitmap >> (31 - p)) & 1];
			}
		}
	}
}

private:

immutable uint[16] palette =
[
	0xff000000,
	0xff0000aa,
	0xff00aa00,
	0xff00aaaa,
	0xffaa0000,
	0xffaa00aa,
	0xffaa5500,
	0xffaaaaaa,
	0xff555555,
	0xff5555ff,
	0xff55ff55,
	0xff55ffff,
	0xffff5555,
	0xffff55ff,
	0xffffff55,
	0xffffffff
];

module demu.emulator.parts.display.tms9918;

import demu.emulator.machine;
import demu.emulator.display;
import demu.emulator.memmap;
import demu.emulator.parts.part;

import std.algorithm;

/*** TODO: lots of modes missing, genesis incomplete ***/

class TMS9918 : Part
{
	enum Version
	{
		TMS9918,
		TMS9918A,		// MSX
		TMS9928A,		// (ColecoVision)
		TMS9929A,		// PAL version
		TMS9938,		// MSX2
		TMS9118,
		TMS9128,
		TMS9129,
		SegaVDP,		// Sega Master System
		YM7101,			// Sega Mega Drive
		V9938,			// Yamaha extended version
		V9958,
		V9990			// Yamaha successor (is this similar, or completely different?)
	}

	this(Machine machine, string name, Version tmsVersion, MemMap dmaMemMap = null, TMS9918 externalVDP = null)
	{
		super(machine, name, Feature.Memory | Feature.Registers);

		this.tmsVersion = tmsVersion;
		this.externalVDP = externalVDP;
		memMap = dmaMemMap;

		regInfo = sRegInfo[0..8]; // stock has 8 regs

		// default chip specs
		displayWidth = 256;
		displayHeight = 192;
		int ramBytes = 16 * 1024;

		regMask[] = gRegisterMasks[0][];

		switch(tmsVersion)
		{
			case Version.SegaVDP:
				regInfo = sRegInfo[0..11]; // SMS has 3 extra regs
				displayWidth = 256;
				displayHeight = 192; //240 PAL
				regMask[] = gRegisterMasks[1][];
				mode = 8; // SMS only has a single display mode
				break;
			case Version.YM7101:
				regInfo = sRegInfo;
				displayWidth = 320;
				displayHeight = 224; //240 PAL (interlaced = 448 / 480)
				ramBytes = 64 * 1024;
				mode = 9; // Genesis has a single display mode, but can also render the SMS mode
				break;
			default:
				break;
		}

		// allocate memory and init the processor
		vRam = new ubyte[ramBytes];

		vdpAddress = 0x0000;
		newVdpAddress = 0xFFFF;
		readLatch = 0x00;
		command = 0;

		// init the VDP regs
		statusRegister = 0;

		if(tmsVersion == Version.SegaVDP)
		{
			// this is the state the SMS bios leaves these registers in
			SetReg(0, 0x36);
			SetReg(1, 0x80);
			SetReg(2, 0xFF);
			SetReg(3, 0xFF);
			SetReg(4, 0xFF);
			SetReg(5, 0xFF);
			SetReg(6, 0xFB);
			SetReg(10, 0xFF);
		}
		else if(tmsVersion == Version.YM7101)
		{
			statusRegister = 0x3600;
			/*
			d15 - Always 0
			d14 - Always 0
			d13 - Always 1
			d12 - Always 1
			d11 - Always 0
			d10 - Always 1
			d9  - FIFO Empty
			d8  - FIFO Full
			d7  - Vertical interrupt pending
			d6  - Sprite overflow on current scan line
			d5  - Sprite collision
			d4  - Odd frame
			d3  - Vertical blanking
			d2  - Horizontal blanking
			d1  - DMA in progress
			d0  - PAL mode flag
			*/
		}
		else
		{
			// upon reset, reg0-1 are cleared
			foreach(a; 0..8)
				SetReg(a, 0);

			foreach(a; 0..32)
				palette[a] = a & 0xF;
		}

		// configure the display
		DisplayProperties desc;
		desc.size = DisplayDimensions(displayWidth, displayHeight);
		desc.rotation = DisplayRotation.None;
		desc.aspectRatio = 4.0f/3.0f;
		Display display = machine.CreateDisplay(desc);

		// create a render layer
		LayerDesc layerDesc;
		layerDesc.size = DisplayDimensions(displayWidth, displayHeight);
		layerDesc.format = Display.Format.D8_RGB24;
		layerDesc.mode = LayerPresentMode.Flip;
		layerDesc.numPaletteEntries = 64;
		layer = &display.ConfigureLayer(0, layerDesc);

		frameBuffer = new ubyte[displayWidth * displayHeight];
	}

	bool BeginFrame() nothrow
	{
		scanLine = 0;
		lineCounter = vdpRegs[10];
		statusRegister |= 0x80;

		return (vdpRegs[1] & 0x20) != 0; // are vblank interrupts enabled?
	}

	bool BeginScanline() nothrow
	{
		if(tmsVersion != Version.SegaVDP)
			return false;

		// handle countdown timer
		if(lineCounter-- == 0)
		{
			lineCounter = vdpRegs[10];

			if(vdpRegs[0] & 0x10)
			{
				statusRegister |= 0x40;
				return true; // signal a scanline interrupt
			}
		}
		return false;
	}

	void DrawFrame(uint[] renderBuffer = null)
	{
		if(!renderBuffer)
			renderBuffer = cast(uint[])layer.DrawBuffer;

		// render the background
		ubyte border = vdpRegs[7] & 0xF;
		ubyte borderColour = palette[border];
		bool bDisplayEnabled = !!(vdpRegs[1] & 0x40);

		immutable(uint)[] palette = sPalette;
		if(tmsVersion == Version.SegaVDP)
		{
			palette = sSMSPalette;
		}
		else if(tmsVersion == Version.YM7101)
		{
			palette = sSMDPalette;

			if(!(vdpRegs[0] & 1))
			{
				// display is switched off (just output black)
				borderColour = 0;
				bDisplayEnabled = false;
			}
		}

		if(borderColour == 0 && externalVDP && (vdpRegs[0] & 1))
		{
			// render the external VDP first, so we can render on top of it
			externalVDP.DrawFrame(renderBuffer);
		}
		else
		{
			int pixels = displayWidth*displayHeight;
			foreach(a; 0..pixels)
				renderBuffer[a] = palette[borderColour];
		}

		// is the display enabled?
		if(!bDisplayEnabled)
			return;

		// render the screen
		foreach(y; 0..displayHeight)
		{
			foreach(x; 0..displayWidth)
			{
				int pixel = y*displayWidth + x;
				if(frameBuffer[pixel] != 0xFF)
				{
					renderBuffer[pixel] = palette[frameBuffer[pixel]];
				}
			}
		}
	}

	void DrawLine()
	{
		if(scanLine >= displayHeight)
			return;

		// get line pointer
		ubyte* pRow = frameBuffer.ptr + scanLine*displayWidth;

		switch(mode)
		{
			case 0: // Graphics 1
				DrawLineGFX1(pRow);
				break;
			case 1: // Graphics 2
				break;
			case 2: // multicolour mode
				break;
			case 4: // Text
				break;
			case 8: // SMS
				DrawLineSMS(pRow);
				break;
			case 9: // Genesis
				DrawLineSMD(pRow);
				break;
			default:
				assert(false, "Unknown display mode!!");
		}

		++scanLine;
	}

	ubyte Read8(uint mode)
	{
		ubyte value;
		newVdpAddress = 0xFFFF;
		mode &= 1;

		if(mode)
		{
			value = cast(ubyte)statusRegister;
			statusRegister = 0;
		}
		else
		{
			value = readLatch;
			readLatch = vRam[vdpAddress++ & 0x3FFF];
		}

		return value;
	}

	void Write8(uint mode, ubyte value)
	{
		mode &= 1;

		if(mode)
		{
			// VDP control port
			if(newVdpAddress == 0xFFFF)
			{
				newVdpAddress = value;
			}
			else
			{
				if((value & 0xC0) == 0xC0)
				{
					command = 3;
					vdpAddress = newVdpAddress & 0x1F;
				}
				else
				{
					if(value & 0x80)
						SetReg(value & 0x1F, cast(ubyte)newVdpAddress);

					command = 0;
					vdpAddress = (newVdpAddress | (value << 8)) & 0x3FFF;

					if((value & 0xC0) == 0)
						readLatch = vRam[vdpAddress++];
				}
				newVdpAddress = 0xFFFF;
			}
		}
		else
		{
			// VDP data port
			newVdpAddress = 0xFFFF;
			if(command == 3)
				palette[vdpAddress++ & 0x1F] = value & 0x3F;
			else
				vRam[vdpAddress++ & 0x3FFF] = readLatch = value;
		}
	}

	ushort Read16(uint mode)
	{
		// used by the Sega Genesis to interface with the 68000
		if(mode)
		{
			// read status port
			return statusRegister;
		}
		else
		{
			// read data port
		}

		return 0;
	}

	void Write16(uint mode, ushort value)
	{
		// used by the Sega Genesis to interface with the 68000
		if(mode)
		{
			// write control port
			if(readLatch)
			{
				readLatch = 0;
				command = (newVdpAddress >> 14) | ((value & 0xF0) >> 2);
				vdpAddress = (newVdpAddress & 0x3FFF) | cast(ushort)(value << 14);

				if((command & 0x30) && (vdpRegs[1] & 0x10))
				{
					// enable DMA
					ushort words = vdpRegs[19] | (vdpRegs[20] << 8);
					if(words == 0)
						words = 0xFFFF;
					uint address68k = ((vdpRegs[21] | (vdpRegs[22] << 8) | (vdpRegs[23] << 16)) << 1) & 0xFFFFFF;

					if(vdpRegs[23] & 0x80)
					{
						// 68k -> VDP
						while(words--)
						{
//							*cast(ushort*)(vRam + vdpAddress) = memMap.Read16_BE_Aligned(address68k);
//							vdpAddress = (vdpAddress + 2) & 0xFFFFFF;
//							address68k += 2;
						}
					}
					else
					{
						if(vdpRegs[23] & 0x40)
						{
							// VRAM copy
						}
						else
						{
							// VRAM fill
						}
					}

					vdpRegs[1] ^= 0x10;
				}
			}
			else
			{
				if(value & 0x8000)
					SetRegSMD((value >> 8) & 0x1F, value & 0xFF);
				else
				{
					newVdpAddress = value;
					readLatch = 1;
				}
			}
		}
		else
		{
			// write data port
		}
	}

protected:
	Version tmsVersion;
	TMS9918 externalVDP;
	MemMap memMap;

	Display.Layer* layer;

	int displayWidth, displayHeight;
	ubyte[] frameBuffer;

	ubyte regMask[8];

	// temp state data
	ubyte* pNameTable;
	ubyte* pNameTableB;
	ubyte* pWindow;
	ubyte* pColourTable;
	ubyte* pPatternGenerator;
	ubyte* pSpriteTable;
	ubyte* pSpriteInfo;
	int mode;

	// state data
	ubyte[] vRam;

	ubyte vdpRegs[32];
	ubyte palette[32];
	ushort cram[64];
	ushort vsram[40];

	int scanLine;
	ubyte lineCounter;
	ubyte readLatch;
	ushort statusRegister;
	ushort vdpAddress;
	ushort newVdpAddress;
	int command;

	void SetReg(int reg, ubyte value)
	{
		vdpRegs[reg] = value;

		switch(reg)
		{
			case 0:
			case 1:
				if(tmsVersion == Version.YM7101)
					mode = (~vdpRegs[1] >> 7) | 8;
				else if(tmsVersion != Version.SegaVDP)
					mode = ((vdpRegs[1] >> 2) & 0x6) | ((vdpRegs[0] >> 1) & 1);
				break;
			case 2:
				if(tmsVersion == Version.SegaVDP && (vdpRegs[1] & 0x10))
					pNameTable = vRam.ptr + 0x700 + ((vdpRegs[2] & 0xC) << 10);
				else
					pNameTable = vRam.ptr + ((vdpRegs[2] & regMask[2]) << 10); // upper 4 bits of 14 bit name table address
				break;
			case 3:
				if(tmsVersion == Version.SegaVDP)
					pColourTable = null;
				else
					pColourTable = vRam.ptr + vdpRegs[3]*0x40;
			case 4:
				pPatternGenerator = vRam.ptr + (vdpRegs[4] & 0x7)*0x800;
			case 5:
				pSpriteInfo = vRam.ptr + ((vdpRegs[5] & regMask[5]) << 7);
				break;
			case 6:
				pSpriteTable = vRam.ptr + (vdpRegs[6] & regMask[6])*0x800;
				break;
			default:
				break;
		}
	}

	void SetRegSMD(int reg, ubyte value)
	{
		vdpRegs[reg] = value;

		switch(reg)
		{
			case 1:
				mode = ((~vdpRegs[1] >> 7) & 1) | 8;
				break;
			case 2:
				pNameTable = vRam.ptr + ((value & 0x38) << 10);
				break;
			case 3:
				pWindow = vRam.ptr + ((value & 0x38) << 10);
				// in 40 cell mode: value & 0x3C
				break;
			case 4:
				pNameTableB = vRam.ptr + ((value & 0x3) << 11);
				break;
			case 5:
				pSpriteInfo = vRam.ptr + ((value & 0x7F) << 9);
				// in 40 cell mode: value & 0x7E
				break;
			case 6:
				pSpriteTable = vRam.ptr + (value & regMask[6])*0x800;
				break;
			default:
				break;
		}
	}

	void DrawLineGFX1(ubyte* pRow)
	{
		if(scanLine >= 24*8)
			return;

		pRow[0..displayWidth] = 0xFF; // clear the row to 0xFF

		// render the sprites
		bool bigSprites = !!(vdpRegs[1] & 0x02);
		bool magSprites = !!(vdpRegs[1] & 0x01);
		uint size = bigSprites ? 16 : 8;

		for(int s=0, lineSprites = 4; s<32; ++s)
		{
			if(!(statusRegister & 0x40))
				statusRegister = (statusRegister & 0xE0) | cast(ushort)s;

			ubyte* pSprite = pSpriteInfo + s*4;
			int y = pSprite[0];

			if(y == 208)
				break;

			uint spriteLine = cast(uint)(scanLine - cast(byte)y - 1);

			if(spriteLine < size)
			{
				if(!lineSprites)
				{
					statusRegister |= 0x40;
					break;
				}

				int x = pSprite[1];

				int image = pSprite[2];
				if(bigSprites)
					image &= 0xFC;
				image *= 8;

				int col = pSprite[3];
				if(col & 0x80)
					x -= 32;

				// calculate horizontal position, range and size
				int left = max(x, 0);
				int right = min(x + cast(int)size, 256);

				ushort line = (pSpriteTable[image + spriteLine] << 8) | (bigSprites ? pSpriteTable[image + spriteLine + 16] : 0);

				// TODO: support fat sprites here by doubling pixels horizontally
				foreach(p; left..right)
				{
					if(line & (0x8000 >> (p - x)))
					{
						if(pRow[p] != 0xFF)
							statusRegister |= 0x20;
						pRow[p] = col & 0xF;
					}
				}

				--lineSprites;
			}
		}

		// render the tilemap
		int y = scanLine >> 3;
		int row = scanLine & 0x7;
		ubyte* pTile = pNameTable + y*32;
		foreach(x; 0..32)
		{
			ubyte tile = *pTile++;
			ubyte line = pPatternGenerator[tile*8 + row];
			ubyte colour = pColourTable[tile >> 3];

			ubyte fg = colour >> 4;
			ubyte bg = colour & 0xF;

			foreach(a; 0..8)
			{
				if(line & (0x80 >> a))
					colour = fg;
				else
					colour = bg;

				if(colour && pRow[a] == 0xFF)
					pRow[a] = colour;
			}

			pRow += 8;
		}
	}

	void DecodeTile(ubyte* pTile, ubyte* pDecodedTile, bool hFlip)
	{
		// decode the row of pixels
		uint row = gTileTable[pTile[0]] | (gTileTable[pTile[1]] << 1) | (gTileTable[pTile[2]] << 2) | (gTileTable[pTile[3]] << 3);

		if(hFlip)
		{
			pDecodedTile[0] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[1] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[2] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[3] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[4] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[5] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[6] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[7] = cast(ubyte)(row & 0xF);
		}
		else
		{
			pDecodedTile[7] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[6] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[5] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[4] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[3] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[2] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[1] = cast(ubyte)(row & 0xF); row >>= 4;
			pDecodedTile[0] = cast(ubyte)(row & 0xF);
		}
	}

	void DrawLineSMS(ubyte* pRow)
	{
		pRow[0..displayWidth] = 0xFF;

		//  ubyte borderColour = vdpRegs[7] & 0xF;

		int numLines = 24;
		int line = scanLine;
		int width = 32;
		int hOffset = 0, hPixels = width*8;
		int hStart = 0;

		if(vdpRegs[1] & 0x10)
			numLines = 28;
		if(vdpRegs[1] & 0x04)
			numLines = 30;

		//  if(vdpRegs[0] & 0x02) // this is supposed to be a wide screen flag or something?
		//  {
		//    width = 33;
		//    hPixels = width*8;
		//  }

		if(!(vdpRegs[0] & 0x40) || scanLine >= 16)
		{
			line = scanLine + vdpRegs[9];
			hOffset = hPixels - vdpRegs[8];
		}

		// clear the left column if enabled
		if((vdpRegs[0] >> 5) & 1)
		{
			hOffset += 8;
			hStart = 8;
		}

		if(scanLine >= numLines*8)
			return;

		// render the sprites
		bool tallSprites = !!(vdpRegs[1] & 0x02);
		uint spriteHeight = tallSprites ? 16 : 8;

		for(int s=0, lineSprites = 8; s<64 && lineSprites; ++s)
		{
			int y = pSpriteInfo[s];

			if(y == 208)
				break;

			uint spriteLine = cast(uint)(scanLine - y);

			if(spriteLine < spriteHeight)
			{
				ubyte tile = pSpriteInfo[129 + s*2];
				if(tallSprites)
					tile &= 0xFE;

				// decode the row of pixels
				ubyte[8] image;
				DecodeTile(pSpriteTable + (tile << 5) + spriteLine*4, image.ptr, false);

				// calculate horizontal position, range and size
				int x = pSpriteInfo[128 + s*2] - ((vdpRegs[0] & 0x08) ? 8 : 0);
				int left = max(x, hStart);
				int right = min(x + 8, hPixels);
				int pixels = right - left;

				// TODO: support fat sprites here by doubling pixels horizontally
				foreach(p; left..right)
				{
					ubyte colour = image[p-x];
					if(colour != 0) // borderColour?
					{
						if(pRow[p] != 0xFF)
							statusRegister |= 0x20;
						pRow[p] = palette[colour + 16];
					}
				}

				--lineSprites;
			}
		}

		// render the tilemap
		int y = (line >> 3) % 28;
		int hPos = hStart;

		while(hPos < hPixels)
		{
			int x = hOffset >> 3;
			ubyte* pTile = pNameTable + (y*width + (x % width))*2;

			int r = line & 0x7;
			if(pTile[1] & 0x04)
				r = 7 - r;

			// decode the tile image
			ubyte[8] image;
			ushort tile = pTile[0] | ((pTile[1] & 0x1) << 8);
			DecodeTile(vRam.ptr + (tile << 5) + r*4, image.ptr, !!(pTile[1] & 0x02));
			int paletteOffset = (pTile[1] & 0x08) ? 16 : 0;

			// blit the image to the screen
			int tileOffset = hOffset & 7;
			int bytes = min(8 - tileOffset, hPixels - hPos);
			bool bBackground = !(pTile[1] & 0x10);
			foreach(a; 0..bytes)
			{
				if(bBackground && pRow[hPos + a] != 0xFF)
					continue;

				ubyte colour = image[tileOffset + a];
				if(colour != 0) // borderColour?
					pRow[hPos + a] = palette[colour + paletteOffset];
			}
			hPos += bytes;
			hOffset += bytes;
		}
	}

	void DrawLineSMD(ubyte* pRow)
	{

	}
}


private:

// palette entries are 0b00BBGGRR in binary
static immutable uint[16] sPalette =
[
	0xFF000000, 0xFF000000, 0xFF40B038, 0xFF78C868,
	0xFF5848F8, 0xFF8070F8, 0xFFB06040, 0xFF58C8E8,
	0xFFD06848, 0xFFF88868, 0xFFC0C840, 0xFFD0D870,
	0xFF389828, 0xFFB060C0, 0xFFC8C8C8, 0xFFFFFFFF
];

static immutable uint[64] sSMSPalette =
[
	0xFF000000, 0xFF550000, 0xFFAA0000, 0xFFFF0000,
	0xFF005500, 0xFF555500, 0xFFAA5500, 0xFFFF5500,
	0xFF00AA00, 0xFF55AA00, 0xFFAAAA00, 0xFFFFAA00,
	0xFF00FF00, 0xFF55FF00, 0xFFAAFF00, 0xFFFFFF00,
	0xFF000055, 0xFF550055, 0xFFAA0055, 0xFFFF0055,
	0xFF005555, 0xFF555555, 0xFFAA5555, 0xFFFF5555,
	0xFF00AA55, 0xFF55AA55, 0xFFAAAA55, 0xFFFFAA55,
	0xFF00FF55, 0xFF55FF55, 0xFFAAFF55, 0xFFFFFF55,
	0xFF0000AA, 0xFF5500AA, 0xFFAA00AA, 0xFFFF00AA,
	0xFF0055AA, 0xFF5555AA, 0xFFAA55AA, 0xFFFF55AA,
	0xFF00AAAA, 0xFF55AAAA, 0xFFAAAAAA, 0xFFFFAAAA,
	0xFF00FFAA, 0xFF55FFAA, 0xFFAAFFAA, 0xFFFFFFAA,
	0xFF0000FF, 0xFF5500FF, 0xFFAA00FF, 0xFFFF00FF,
	0xFF0055FF, 0xFF5555FF, 0xFFAA55FF, 0xFFFF55FF,
	0xFF00AAFF, 0xFF55AAFF, 0xFFAAAAFF, 0xFFFFAAFF,
	0xFF00FFFF, 0xFF55FFFF, 0xFFAAFFFF, 0xFFFFFFFF
];

static immutable uint[512] sSMDPalette =
[
	0xFF000000
];

static immutable uint[256] gTileTable =
{
	// init some static table data
	uint[256] t;
	foreach(a; 0..256)
	{
		t[a] = 0;

		foreach(b; 0..8)
		{
			if(a & (1 << b))
				t[a] |= 1 << (b*4);
		}
	}
	return t[];
}();

static immutable RegisterInfo[] sRegInfo =
[
	RegisterInfo( "Mode", 8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "Scanline", 8, RegisterInfo.Flags.ReadOnly, null ),
	RegisterInfo( "Status", 8, RegisterInfo.Flags.ReadOnly, "FSC11111" ),
	RegisterInfo( "R0", 8, 0, null ),
	RegisterInfo( "R1", 8, 0, null ),
	RegisterInfo( "R2", 8, 0, null ),
	RegisterInfo( "R3", 8, 0, null ),
	RegisterInfo( "R4", 8, 0, null ),
	RegisterInfo( "R5", 8, 0, null ),
	RegisterInfo( "R6", 8, 0, null ),
	RegisterInfo( "R7", 8, 0, null ),
	RegisterInfo( "R8", 8, 0, null ),
	RegisterInfo( "R9", 8, 0, null ),
	RegisterInfo( "R10", 8, 0, null ),
	RegisterInfo( "R11", 8, 0, null ),
	RegisterInfo( "R12", 8, 0, null ),
	RegisterInfo( "R13", 8, 0, null ),
	RegisterInfo( "R14", 8, 0, null ),
	RegisterInfo( "R15", 8, 0, null ),
	RegisterInfo( "R16", 8, 0, null ),
	RegisterInfo( "R17", 8, 0, null ),
	RegisterInfo( "R18", 8, 0, null ),
	RegisterInfo( "R19", 8, 0, null ),
	RegisterInfo( "R20", 8, 0, null ),
	RegisterInfo( "R21", 8, 0, null ),
	RegisterInfo( "R22", 8, 0, null ),
	RegisterInfo( "R23", 8, 0, null )
];

static immutable ubyte gRegisterMasks[8][] =
[
	[ 0xFF, 0xFF, 0x0F, 0xFF, 0xFF, 0x7F, 0x07, 0xFF ], // no masking
	[ 0xFF, 0xFF, 0x0E, 0xFF, 0xFF, 0x7E, 0x04, 0xFF ]  // SMS register masks
];

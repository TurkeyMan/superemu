module demu.emulator.display;

import demu.emulator.machine;
import std.math;

enum LayerPresentMode
{
	Flip = 0,
	Copy
}

enum DisplayRotation
{
	None = 0,
	CW90,
	CCW90,
	Rot180,
	HFlip,
	VFlip
}

struct DisplayDimensions
{
	int width, height;

	@property int numPixels() const { return width * height; }
}

struct DisplayProperties
{
	DisplayDimensions size;
	DisplayRotation rotation;
	float aspectRatio;

//	Dispaly.Filter filter;
}

struct LayerDesc
{
	DisplayDimensions size;
	Display.Format format;
	LayerPresentMode mode;
	int numPaletteEntries;

//	ushort[] hScrollOffsets;
//	ushort[] vScrollOffsets;
//	int scrollPixelsH;
//	int scrollPixelsV;
}

class Display
{
	enum Filter
	{
		None = 0,
		Scale2x,
		Scale3x,
		Scale4x,
		Eagle,
	}

	enum Format
	{
		D8_RGB24 = 0, // typical ARGB, with depth stored in alpha
		D4_I12,       // 16 bit format with 4 bits depth, and 12 bit palette index
		S1_D3_I12,    // 16 bit format with 1 bit shadow, 3 bits depth, and 12 bits palette
		D2_I6         // 8 bit format with 2 bit depth, and 6 bit palette index
	}

	struct Layer
	{
		@property ref const(LayerDesc) Descriptor() const { return desc; }

		@property ubyte[] DrawBuffer() { return layerBuffer[currentBackBuffer]; }

		void Clear()
		{
			layerBuffer[currentBackBuffer][] = 0;
		}

		void SetDirty() { bDirty = true; }

		void SetPalette(uint[] palette)
		{
			pendingPalette = palette;
		}

	private:
		LayerDesc desc;

		ubyte[][2] layerBuffer;
		int currentBackBuffer;

		uint[] palette;
		uint[] pendingPalette;

		bool bDirty;

		void Configure(const ref LayerDesc desc)
		{
			this.desc = desc;

			foreach(ref buffer; layerBuffer)
				buffer = new ubyte[desc.size.numPixels * 4]; // TODO: allocate the correct size for the layer format

			palette = new uint[desc.numPaletteEntries];
		}

		@property ubyte[] DisplayBuffer() { return layerBuffer[1 - currentBackBuffer]; }
	}

	// methods
	this(ref DisplayProperties display, int numLayers)
	{
		this.display = display;

		drawBuffer = new uint[display.size.numPixels];
		layers = new Layer[numLayers];

		SetColourCurve();
	}

	@property ref const(DisplayDimensions) DisplaySize() const { return display.size; }
	@property float AspectRatio() const { return display.aspectRatio; }

	@property uint[] DrawBuffer() { return drawBuffer; }

	void Resize(DisplayDimensions size)
	{
		display.size = size;
		drawBuffer = new uint[size.numPixels];
	}

	ref Layer ConfigureLayer(int layer, const ref LayerDesc desc)
	{
		layers[layer].Configure(desc);
		return layers[layer];
	}

	ref Layer GetLayer(int layer)
	{
		return layers[layer];
	}

	void SetPalette(uint[] palette)
	{
		pendingPalette = palette;

		if(!this.palette)
			this.palette = new uint[palette.length];
	}

	void SetColourCurve(float brightness = 0.0f, float contrast = 1.0f, float gamma = 1.0f)
	{
		foreach(i; 0..256)
		{
			float fi = cast(float)i / 255.0f;
			float c = ((fi - 0.5f) * contrast) + 0.5f;
			float b = clamp(0.0f, c + brightness, 1.0f);
			float g = clamp(0.0f, pow(b, gamma), 1.0f);
			colourCurveTable[i] = cast(ubyte)(g * 255.0f);
		}
	}

	void SwapBuffers()
	{
		// update system palette
		if(pendingPalette)
		{
			foreach(i; 0..palette.length)
				palette[i] = Modify(pendingPalette[i], colourCurveTable);
			pendingPalette = null;
		}

		// swap layers
		foreach(ref layer; layers)
		{
			if(layer.desc.mode == LayerPresentMode.Copy)
			{
				if(layer.bDirty)
				{
					layer.layerBuffer[1][] = layer.layerBuffer[0][];
					layer.bDirty = false;
				}
			}
			else
			{
				layer.currentBackBuffer = 1 - layer.currentBackBuffer;
			}

			if(layer.pendingPalette)
			{
				foreach(i; 0..layer.palette.length)
					layer.palette[i] = Modify(layer.pendingPalette[i], colourCurveTable);
				layer.pendingPalette = null;
			}
		}
	}

	void Draw(uint[] frameBuffer)
	{
		RenderFrame(frameBuffer);

//		frameBuffer[] = drawBuffer[];
/+
		// if we're running with threaded rendering, wait for the frame to complete
		if(bUseThreadedRendering)
		{
			if(bRenderPending)
			{
				WaitSemaphore(pDrawSemaphore);
				bRenderPending = false;
			}

			// copy frame to the texture
			int step = 1, advanceLine = frameBufferSize.width;
			uint* pLine = pFrontBuffer;

			switch(rotation)
			{
				case SR_None:
					SEMemCopy(pFrameBuffer, pFrontBuffer, frameBufferSize.width * frameBufferSize.height * sizeof(uint));
					break;

				case SR_90CW:
					pLine = pFrontBuffer + frameBufferSize.width*(frameBufferSize.height-1);
					step = -frameBufferSize.width;
					advanceLine = 1;
					goto copy_transformed;

				case SR_90CCW:
					pLine = pFrontBuffer + frameBufferSize.width-1;
					step = frameBufferSize.width;
					advanceLine = -1;
					goto copy_transformed;

				case SR_180:
					pLine = pFrontBuffer + frameBufferSize.width*(frameBufferSize.height-1) + frameBufferSize.width-1;
					step = -1;
					advanceLine = -frameBufferSize.width;
					goto copy_transformed;

				case SR_HFlip:
					pLine = pFrontBuffer + frameBufferSize.width-1;
					step = -1;
					advanceLine = frameBufferSize.width;
					goto copy_transformed;

				case SR_VFlip:
					pLine = pFrontBuffer + frameBufferSize.width*(frameBufferSize.height-1);
					step = 1;
					advanceLine = -frameBufferSize.width;
					goto copy_transformed;

				copy_transformed:
				{
					// blit a transformed copy of the image
					for(int y=0; y<displaySize.height; ++y)
					{
						uint* pPixel = pLine;
						for(int x=0; x<displaySize.width; ++x)
						{
							*pFrameBuffer++ = *pPixel;
							pPixel += step;
						}

						pLine += advanceLine;
					}
					break;
				}
			}
		}
		else
		{
			RenderFrame(pFrameBuffer);
		}
+/
	}

private:
	DisplayProperties display;
	Layer[] layers;

	uint[] drawBuffer;

	uint[] palette;
	uint[] pendingPalette;

	ubyte[256] colourCurveTable;

	// render functions
	void RenderFrame(uint[] drawBuffer)
	{
		assert(layers.length == 1, "Only single layer suported currently...");

		RenderSingleLayer(drawBuffer);
	}

	void RenderSingleLayer(uint[] frameBuffer)
	{
		uint* pOut = frameBuffer.ptr;
		int targetWidth = display.size.width;
		int targetHeight = display.size.height;

		Layer* layer = &layers[0];
		uint[] layerPalette = layer.palette ? layer.palette : palette;

		int layerOffset = 0;//layer.width*layer.vOffset + layer.hOffset;

		final switch(layer.desc.format)
		{
			case Format.D8_RGB24:
			{
				// render 32bit display
				uint* pSrc = cast(uint*)layer.DisplayBuffer.ptr;
				pSrc += layerOffset;

				// TODO: *** SUPPORT SCROLL OFFSETS ***

				foreach(y; 0..targetHeight)
				{
					foreach(x; 0..targetWidth)
						pOut[x] = 0xFF000000 | pSrc[x];

					pOut += targetWidth;
					pSrc += layer.desc.size.width;
				}
				break;
			}
			case Format.D4_I12:
			case Format.S1_D3_I12:
			{
				/+
				// render 16bit display
				ushort* pSrc = (ushort*)layer.pDisplayBuffer[1 - layer.fbIndex];
				pSrc += layerOffset;

				// TODO: *** SUPPORT SCROLL OFFSETS ***

				for(int y = 0; y < targetHeight; ++y)
				{
					for(int x = 0; x < targetWidth; ++x)
						pOut[x] = pLayerPalette[pSrc[x] & 0xFFF];

					pOut += targetWidth;
					pSrc += layer.width;
				}
+/
				break;
			}
			case Format.D2_I6:
			{
/+
				// render 8bit display
				ubyte* pSrc = (ubyte*)layer.pDisplayBuffer[1 - layer.fbIndex];
				pSrc += layerOffset;

				// TODO: *** SUPPORT SCROLL OFFSETS ***

				for(int y = 0; y < targetHeight; ++y)
				{
					for(int x = 0; x < targetWidth; ++x)
						pOut[x] = pLayerPalette[pSrc[x] & 0x3F];

					pOut += targetWidth;
					pSrc += layer.width;
				}
+/
				break;
			}
		}
	}
}

private:

// util functions used by Display


// return 0 or 1
ubyte GetBit(const ubyte* pSrc, uint bit)
{
    return (pSrc[bit >> 3] >> (7 - (bit & 7))) & 1;
}

uint ToARGB(ubyte a, ubyte r, ubyte g, ubyte b)
{
    return (a << 24) | (r << 16) | (g << 8) | b;
}

ubyte Expand3to8(ushort bits)
{
    bits &= 0x7;
    return cast(byte)((bits << 5) | (bits << 2) | (bits >> 1));
}

ubyte Expand4to8(ushort bits)
{
    bits &= 0xF;
    return cast(ubyte)((bits << 4) | bits);
}

ubyte Expand5to8(ushort bits)
{
    bits &= 0x1F;
    return cast(ubyte)((bits << 3) | (bits >> 2));
}

ubyte Expand6to8(ushort bits)
{
    bits &= 0x3F;
    return cast(ubyte)((bits << 2) | (bits >> 4));
}

ubyte Expand7to8(ushort bits)
{
    bits &= 0x7F;
    return cast(ubyte)((bits << 1) | (bits >> 6));
}

uint ExpandColourR3G3B2(ubyte colour, ubyte a = 0xFF)
{
    ubyte r = ((colour & 0x07) << 5) | ((colour & 0x07) << 2) | ((colour & 0x07) >> 1);
    ubyte g = ((colour & 0x38) << 2) | ((colour & 0x38) >> 1) | ((colour & 0x38) >> 4);
    ubyte b = ((colour & 0xC0) >> 0) | ((colour & 0xC0) >> 2) | ((colour & 0xC0) >> 4) | ((colour & 0xC0) >> 6);
    return ToARGB(a, r, g, b);
}

uint Modify(uint colour, ubyte[] lookup)
{
    uint b = colour & 0xFF;
    uint g = (colour >> 8 ) & 0xFF;
    uint r = (colour >> 16) & 0xFF;
    uint a = (colour >> 24) & 0xFF;

    ubyte lb = lookup[b];
    ubyte lg = lookup[g];
    ubyte lr = lookup[r];
    ubyte la = cast(ubyte)a;

    return ToARGB(la, lr, lg, lb);
}

module demu.emulator.machine;

import demu.rommanager.romdatabase;
import demu.rommanager.game;

import demu.emulator.display;
import demu.emulator.executor;
import demu.emulator.parts.part;
import demu.emulator.parts.processor;
import demu.emulator.debugger;

import std.algorithm;
import std.stdio;

version(DigitalMars)
	import core.bitop;
else version(GNU)
	import gcc.builtins;

// define a pile of feature switches
version(LittleEndian)
{
	enum Endian SystemEndian = Endian.Little;
	enum bool LittleEndian = true;
	enum bool BigEndian = false;
}
else
{
	enum Endian SystemEndian = Endian.Big;
	enum bool LittleEndian = false;
	enum bool BigEndian = true;
}

enum bool EnableDebugger = false;
enum bool EnableExecutionLogging = true;
enum bool EnableDissassembly = EnableDebugger || EnableExecutionLogging;
enum bool EnableMemTracker = EnableDebugger || true;
enum bool EnableSystemHalt = EnableDebugger;

enum bool EnableMemTracking = true;

// enums

enum Endian
{
	Little,
	Big
}

// handy stuff
T alignTo(size_t A, T)(T v) pure nothrow
{
	return cast(T)((v + (A-1)) & ~(A-1));
}

T clamp(T)(T least, T val, T most) pure nothrow
{
	return min(max(least, val), most);
}

template bit(size_t B)
{
	enum bit = 1 << B;
}

uint nextPowerOf2(uint v)
{
	v--;
	v |= v >> 1;
	v |= v >> 2;
	v |= v >> 4;
	v |= v >> 8;
	v |= v >> 16;
	return ++v;
}

uint maskSize(uint v)
{
	return nextPowerOf2(v)-1;
}

// machine class
class Machine
{
	alias bool delegate(int timerIndex, long tick) CountdownTimerDelegate;

	this(const(RomInstance)* romDesc, RomDatabase db)
	{
		machineDescription = romDesc;

		systemClock = 0;
		systemClockLimit = long.max;
		minStep = 1;
	}

	// machine configuration
	Display CreateDisplay(ref DisplayProperties displayProperties, int numLayers = 1)
	{
		display = new Display(displayProperties, numLayers);
		return display;
	}

	Display GetDisplay() nothrow
	{
		return display;
	}

	int AddPart(Part part)
	{
		assert(!FindPart(part.Name), "Component with the same name already exists!");

		int id = cast(int)parts.length;
		parts ~= part;
		return id;
	}

	@property Part[] Parts() nothrow { return parts; }

	Part FindPart(string name)
	{
		foreach(ref p; parts)
		{
			if(name[] == p.Name[])
				return p;
		}
		return null;
	}

	void AddProcessor(Processor processor, uint clockDivide)
	{
		processors ~= processor;
		processor.clockDivider = clockDivide;

//		qsort(processors, processors.length, sizeof(Processor), Processor::SortProc);
	}

	@property Processor[] Processors() nothrow { return processors; }

	int AddCountdownTimer(int interval, int startTime, CountdownTimerDelegate callback)
	{
		timers ~= startTime;
		timerInterval ~= interval;
		timerCallbacks ~= callback;
		return cast(uint)timerCallbacks.length;
	}

	void ResetCountdownTimer(int index, int cycles) nothrow
	{
		timers[index] = cycles;
	}

	// machine interface
	void UpdateMachine()//GPStateData* pStateData)
	{
/+
		// get the ingame state
		pStateData->bIsPlaying = IsPlaying();

		// save state requested
		if(pStateData->pSaveStateBuffer)
		{
			if(saveStateSize == -1 || m_streamBreakpointSize != -1)
				saveStateSize = GetSaveSize();

			assert(pStateData->saveBufferSize <= saveStateSize, "Save buffer is too small!");

			// dump the emulator state
			SaveStateToBuffer(pStateData->pSaveStateBuffer);
			pStateData->saveBufferSize = saveStateSize;
		}

		// load state was requested
		if(pStateData->pLoadStateBuffer)
			pStateData->bLoadSucceeded = LoadStateFromBuffer(pStateData->pLoadStateBuffer);

		// restore NVRAM if it was requested
		if(pStateData->pNVRAMRestoreData)
			RestoreNVRam((uint8*)pStateData->pNVRAMRestoreData, pStateData->nvramSize);
+/
		// swap display buffers
		display.SwapBuffers();

/+
		// notify the machine if the viewport was resized
		if(pStateData->viewportSize.width != frameBufferSize.width && pStateData->viewportSize.height != frameBufferSize.height)
		{
			if(pStateData->viewportSize.width != 0 && pStateData->viewportSize.height != 0)
				OnResizeViewport(&pStateData->viewportSize);
		}

		m_score = (int)GetScore(PNUM_Player1);
+/

		// run the machines system update
		Update();

		// execute one frame
		ExecuteFrame();
		++frameNumber;
	}

	void Draw(uint[] frameBuffer)
	{
		display.Draw(frameBuffer);
	}

	// execution control
	abstract void Reset();
	void ResetToServiceMode() { Reset(); }

	void YieldExecution() nothrow { bYield = true; }
	void Halt() nothrow { systemClockLimit = systemClock; }
	void Run() nothrow { systemClockLimit = 0x7FFF_FFFF_FFFF_FFFF; }

	void SetMinimumStep(uint numCycles) nothrow { minStep = numCycles; }
	@property long SystemClock() const nothrow { return systemClock; }

	// debug + logging
	@property Debugger Dbg() nothrow { return debugger; }

	int OpenLogFile()
	{
/*
		if(logRefCount++ == 0)
		{
			char filename[256];
			const char* pMachineName = m_pMachineDescription->GetName();
			sprintf_s(filename, 256, "//home/%s_%06d.txt", pMachineName, logInstance);
			pLogFile = FileOpen(filename, static_cast<OpenMode>(WriteTruncate | CreateDirectory));
		}

		return logRefCount;
*/
		return 0;
	}

	int CloseLogFile()
	{
/*
		if(--logRefCount == 0)
		{
			FileClose(&pLogFile);
			++logInstance;
		}

		return logRefCount;
*/
		return 0;
	}

	void LogMessage(const(char)[] message, LogTarget target)
	{
		if(target == LogTarget.File)
		{
			//...
		}
		else if(target == LogTarget.Console)
		{
			version(x)//Windows)
			{
//				import win32.windows: OutputDebugString;

				OutputDebugString(message.ptr);
			}
			else
			{
				writeln(message);
			}
		}
	}

protected:
	const(RomInstance*) machineDescription;

	Display display;

	// Executor[] exec;

	long systemClock;
	long systemClockLimit;
	uint minStep;

	bool bYield;

	Debugger debugger;

	abstract void Update();

	void OnResizeDisplay(ref DisplayDimensions size)
	{
		size = display.DisplaySize; // reject the resize by overwriting the requested size with the current size
	}

	uint ReleaseIRQ(Processor processor) nothrow
	{
		processor.SignalIRQ(0);
		return 0;
	}

private:
	Part[] parts;
	Processor[] processors;

	int[] timerInterval;
	int[] timers;
	CountdownTimerDelegate[] timerCallbacks;

	int frameNumber;

	void ExecuteFrame()
	{
		if(processors.length == 0)
			return;

		bYield = false;

		long nextTimer = 0;
		long lastTimer = systemClock;

		static if(EnableSystemHalt)
			bYield |= systemClock >= systemClockLimit;

		// while nothing yields execution
		while(!bYield)
		{
			// find the next processor to execute
			long next = 0xFFFF; // the largest immediate number possible
			uint mask = 0;

			foreach(a; 0..processors.length)
			{
				long diff = processors[a].lastClock - systemClock;
				if(diff < next)
				{
					next = diff;
					mask = 1 << a;
				}
				else if(diff == next)
				{
					mask |= 1 << a;
				}
			}

			// increment the system timer
			systemClock += next;

			// check countdown timers
			nextTimer -= next;
			if(nextTimer <= 0)
			{
				nextTimer = 0x4000_0000;
				lastTimer = systemClock - lastTimer;

				foreach(a; 0..timerCallbacks.length)
				{
					int counter = timers[a] - cast(int)lastTimer;
					if(counter <= 0)
					{
						if(timerCallbacks[a](cast(int)a, systemClock + counter))
							bYield = true;
						counter += timerInterval[a];
					}
					timers[a] = counter;

					if(counter < nextTimer)
						nextTimer = counter;
				}

				lastTimer = systemClock;
			}

			// execute each processor that lands on this tick
			uint i;
			while(mask)
			{
				version(DigitalMars)
					i = bsr(mask);
				else version(GNU)
					i = __builtin_ctz(mask);

				mask ^= 1 << i;

				Processor proc = processors[i];

				int cycles = proc.Execute(minStep) * proc.clockDivider;
				proc.lastClock += cycles;

				if(cycles == 0)
				{
					if(proc.IsReady())
						Halt();
				}
			}

			static if(EnableSystemHalt)
				bYield |= systemClock >= systemClockLimit;
		}
	}

	ubyte Read8Nop(uint address) const pure nothrow
	{
		return 0x0;
	}

	void Write8Nop(uint address, ubyte value) const pure nothrow
	{
	}
}

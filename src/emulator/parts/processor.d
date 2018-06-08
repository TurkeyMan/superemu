module demu.emulator.parts.processor;

import demu.emulator.machine;
import demu.emulator.parts.part;

import std.string;
import demu.tools.util;

class Processor : Part
{
	alias uint delegate(Processor processor) EventDelegate;
	alias void delegate(Processor processor, DisassembledOp* pInstruction) ExecutionLogHandler;

	this(Machine machine, string name, uint features)
	{
		super(machine, name, features);

		clockDivider = 1;
		bReady = true;
	}

	override @property const(ProcessorInfo)* ProcInfo() const nothrow { return &procInfo; }

	@property uint AddressMask() const nothrow { return procInfo.addressMask; }
	@property void AddressMask(uint mask) nothrow { procInfo.addressMask = mask; }

	// program control
	/+virtual+/ uint Reset()
	{
		bNMIPending = false;
		irqLineState = 0;

		return startAddress;
	}

	/+virtual+/ void SetProgramCounter(uint pc) nothrow
	{
		// base does nothing
	}

	// execution
	@property bool IsReady() const nothrow { return bReady; }

	void SetReady(bool ready, ulong startingClock = -1) nothrow
	{
		bReady = ready;
		if(ready)
			lastClock = startingClock != -1 ? startingClock : machine.SystemClock; // NOTE: This shouldn't be used, ALWAYS supply a startingClock
		else
			lastClock = 0x4000_0000_0000_0000;
	}

	void Halt() nothrow { bYield = true; } // forces an immediate yield

	abstract int Execute(int numCycles, uint breakConditions = 0);

	// IRQ/signaling
	void SignalIRQ(int irqLevel) nothrow { irqLineState = irqLevel; }
	void TriggerNMI() nothrow { bNMIPending = true; }

	@property void IntAckCallback(EventDelegate callback) nothrow { intAckHandler = callback; }
	@property EventDelegate IntAckCallback() const nothrow { return intAckHandler; }
	@property void ResetCallback(EventDelegate callback) nothrow { resetHandler = callback; }
	@property EventDelegate ResetCallback() const nothrow { return resetHandler; }

	// timing
	void AddWaitCycles(uint cycles) nothrow { waitCycles = cycles; }

	@property ulong CycleCount() const nothrow { return cycleCount; }
	@property void CycleCount(ulong cycles) nothrow { cycleCount = cycles; }
	@property ulong OpCount() const nothrow { return opCount; }
	void ResetCycleCount() nothrow { cycleCount = 0; }

	long lastClock;
	//	@property long LastClock() const nothrow { return lastClock; }
//	@property void LastClock(long clock) nothrow { lastClock = clock; }
	void AddClocks(long ticks) nothrow { lastClock += ticks; }

	uint clockDivider;
//	@property uint ClockDivider() const nothrow { return clockDivider; }
//	@property void ClockDivider(uint divider) nothrow { clockDivider = divider; }

	// execution logging
	static if(EnableExecutionLogging)
	{
		int LogExecution(LogTarget target, bool bEnabled)
		{
			if(bEnabled)
			{
				if(logTargets[target]++ == 0 && target == LogTarget.File)
					machine.OpenLogFile();
			}
			else
			{
				assert(logTargets[target] > 0, "Too many LogExecution(false)'s");
				if(--logTargets[target] == 0 && target == LogTarget.File)
					machine.CloseLogFile();
			}

			bLogExecution = false;
			foreach(a; 0 .. cast(int)LogTarget.NumTargets)
				bLogExecution = bLogExecution || logTargets[a] > 0;

			return logTargets[target];
		}

		ExecutionLogHandler SetUserLogHandler(ExecutionLogHandler logHandler) nothrow
		{
			ExecutionLogHandler old = userLogHandler;
			userLogHandler = logHandler;
			return old;
		}
	}

protected:
	ProcessorInfo procInfo;

	EventDelegate intAckHandler;
	EventDelegate resetHandler;

//	long lastClock;     // last time this processor issues an instruction
	long cycleCount;    // the number of cycles this processor has executed
	long opCount;       // the number of instructions this processor has executed
//	uint clockDivider;  // this processors division of the master clock rate

	uint waitCycles;

	int irqLineState;
	int bNMIPending;

	bool bReady;
	bool bYield;

	static if(EnableExecutionLogging)
	{
		bool bLogExecution;
		ExecutionLogHandler userLogHandler;

		static if(EnableDissassembly)
		{
			void WriteToLog(DisassembledOp* pLine)
			{
				if(logTargets[LogTarget.User])
					userLogHandler(this, pLine);

				DefaultLogHandler(pLine);
			}

			void DefaultLogHandler(DisassembledOp* pLine)
			{
				StaticString!512 line; // it would be nice to reserve 512 bytes or something...

				uint pc = pLine.programOffset;

				// add a line label
				const(AddressInfo)* pAddrInfo = GetSymbol(pc);
				if(pAddrInfo)
				{
					string label = pAddrInfo.CodeLabel;
					if(label)
						line.formatAppend("%s:\r\n", label);
				}

				// add the program offset
				int addressDigits = (procInfo.addressWidth + 3) >> 2;
				line.formatAppend("$%0*X", addressDigits, pc);

				// add the program code?
				char[64] temp;
				int maxProgramCodeLength = procInfo.maxOpwords * ((procInfo.opcodeWidth + 3) >> 2) + (procInfo.opcodeWidth > 8 ? procInfo.maxOpwords - 1 : 0);
				size_t pcBytes = pLine.GetProgramCode(temp, procInfo.opcodeWidth).length;
				temp[pcBytes++] = ']';
				line.formatAppend(" [%-*s", maxProgramCodeLength + 1, temp[0..pcBytes]);

				// add the disassebly
				line.formatAppend(" %-*s", procInfo.maxAsmLineLength + 2, pLine.GetAsm(temp, false, this));

				// add the registers
				size_t regStart = line.length;
				size_t numRegs = displayRegs ? displayRegs.length : regInfo.length;

				foreach(a; 0..numRegs)
				{
					int r = displayRegs ? displayRegs[a] : cast(int)a;
					if(r >= 0)
					{
						line.formatAppend(" %s:", regInfo[r].name);
						line ~= GetRegisterValueAsString(temp, r);
					}
					else
					{
						// we'll support some simple formatting...
						switch(r)
						{
							case -1:
								line ~= " -";
								break;
							case -2:
								line.formatAppend("\r\n%*s", regStart, "");
								break;
							default:
								break;
						}
					}
				}

				// add the cycle count and end the line
				line.formatAppend(" (%d)\r\n\0", CycleCount);

				// write it to the log
				LogMessage(line);
			}
		}
	}
}

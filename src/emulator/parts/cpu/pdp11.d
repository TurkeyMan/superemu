module demu.emulator.parts.cpu.pdp11;

import demu.emulator.machine;
import demu.emulator.memmap;
import demu.emulator.parts.part;
import demu.emulator.parts.processor;

import std.string;

class DEC_PDP11 : Processor
{
	enum Version
	{
		DEC_T11
	}

	this(Machine machine, string name, MemMap memmap, Version processorRevision)
	{
		super(machine, name, Part.Feature.Stack | Part.Feature.Code | Part.Feature.Registers);
		MemoryMap = memmap;

		this.processorRevision = processorRevision;

		procInfo.name = sProcessorName[processorRevision];
		procInfo.processorFamily = "DEC PDP-11";
		procInfo.endian = Endian.Little;
		procInfo.addressWidth = 16;
		procInfo.addressMask = 0xFFFF;
		procInfo.stackOffset = 0;
		procInfo.opcodeWidth = 16;
		procInfo.maxOpwords = 3;
		procInfo.maxAsmLineLength = 12;

		regInfo = sRegInfo;
	}

	override uint Reset()
	{
		registers = Registers.init;

		startAddress = 0x1000; // does it begin here, or is the reset vector here?

		registers.r[7] = cast(ushort)startAddress;

		return super.Reset();
	}

	override void SetProgramCounter(uint pc) nothrow
	{
		registers.r[7] = cast(ushort)pc;
	}

	override int Execute(int numCycles, uint breakConditions)
	{
		int remainingCycles = numCycles;
		while(remainingCycles > 0)
		{
			// check for interrupts
/*
			if(opcodeTable[instruction].interruptible)
			{
				if(irqLineState)
				{
//					DebugJumpToSub(registers.r[7], 0x1004, bNMIPending ? 0 : 1);

					// acknowledge the interrupt
					bNMIPending = false;
					if(pIntAck)
					(machine.*pIntAck)(this);

					// handle interrupt
					memmap.Write16_BE_Aligned(registers.r[6]++, registers.r[7]);
					registers.r[7] = 0x1004; // jump to the interrupt vector...
					cycleCount += 7;
					}
			}
*/

			// allow the debugger to step the cpu
			if(machine.Dbg.BeginStep(this, registers.r[7]))
				break;

			static if(EnableDissassembly)
			{
				// log the instruction stream
				DisassembledOp disOp;
				bool bDisOpValid = false;
				uint pc = registers.r[7];
				if(bLogExecution)
					bDisOpValid = !!DisassembleOpcode(registers.r[7], &disOp);
			}

//			TRACK_OPCODE(registers.r[7]);
			ushort opcode = memmap.Read16_BE_Aligned(registers.r[7]++);

			// decode the instruction
			Instruction instruction = Instruction.Unknown;
			AddressMode am1 = AddressMode.Unknown;
			AddressMode am2 = AddressMode.Unknown;

			ulong cc = cycleCount;
//			cycleCount += sOpcodeTable[instruction].cc;
			waitCycles = 0;

			int address = 0;
			int operand = 0;
			int target = 0;
/*
			if(am1 > AM_Unknown)
			{

			}

			if(am2 > AM_Unknown)
			{

			}

			switch(instruction)
			{
				default:
				{
//					machine.DebugBreak("Illegal opcode", BR_IllegalOpcode);
					assert(false, "Unknown opcode!");
					break;
				}
			}
*/

			static if(EnableDissassembly)
			{
				if(bDisOpValid)
					WriteToLog(&disOp);
			}

			cycleCount += waitCycles;
			remainingCycles -= cast(int)(cycleCount - cc);
			++opCount;
		}

		// return the number of cycles actually executed
		return numCycles - remainingCycles;
	}

	override uint GetRegisterValue(int reg)
	{
		if(reg < 8)
			return registers.r[reg];
		else if(reg == 8)
			return registers.swd;
		return -1;
	}

	override void SetRegisterValue(int reg, uint value)
	{
		if(reg < 8)
			registers.r[reg] = cast(ushort)value;
		else if(reg == 8)
			registers.swd = cast(ushort)value;
	}

	override int DisassembleOpcode(uint address, DisassembledOp* pOpcode)
	{
		*pOpcode = DisassembledOp.init;
		pOpcode.programOffset = address & procInfo.addressMask;

		ushort opcode = memmap.Read16_BE_Aligned(address++);
		pOpcode.programCode[pOpcode.pcWords++] = opcode;

		return 0;
	}
private:
	Version processorRevision;

	Registers registers;

}

struct Registers
{
	ushort[8] r; // 8 general purpose registers
	ushort swd;  // status word
}

struct Opcode
{
    ubyte op;
    ubyte am1;
    ubyte am2;
    ubyte cc;
}

enum : ushort
{
    SR_Carry = 0x01,
    SR_Overflow = 0x02,
    SR_Zero = 0x04,
    SR_Negative = 0x08,

    SR_Trace = 0x10,
    SR_Priority = 0xE0
}

enum Instruction
{
    HALT,
    WAIT,
    RESET,
    NOP,

    Max,

    Unknown = 255,	// Unknown opcode
}

enum AddressMode
{
    Unknown = -1,

    Register = 0,
    RegisterDeferred,
    Autoincrement,
    AutoincrementDeferred,
    Autodecrement,
    AutodecrementDeferred,
    Index,
    IndexDeferred,

    Max
}

immutable RegisterInfo[] sRegInfo =
[
	RegisterInfo( "R0", 16, 0, null ),
	RegisterInfo( "R1", 16, 0, null ),
	RegisterInfo( "R2", 16, 0, null ),
	RegisterInfo( "R3", 16, 0, null ),
	RegisterInfo( "R4", 16, 0, null ),
	RegisterInfo( "R5", 16, 0, null ),
	RegisterInfo( "SP", 16, RegisterInfo.Flags.StackPointer, null ),
	RegisterInfo( "PC", 16, RegisterInfo.Flags.ProgramCounter, null ),
	RegisterInfo( "SWD", 16, RegisterInfo.Flags.FlagsRegister, "........421TNZOC" )
];

static string[] sProcessorName =
[
	"DEC T-11"
];

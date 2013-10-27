module demu.emulator.parts.cpu.dcpu16;

import demu.emulator.machine;
import demu.emulator.memmap;
import demu.emulator.parts.part;
import demu.emulator.parts.processor;

import std.string;

class DCPU_16 : Processor
{
	this(Machine machine, string name, MemMap memmap)
	{
		super(machine, name, Part.Feature.Stack | Part.Feature.Code | Part.Feature.Registers);
		MemoryMap = memmap;

		procInfo.name = "DCPU-16";
		procInfo.processorFamily = "DCPU-16";
		procInfo.endian = Endian.Little;
		procInfo.addressWidth = 16;
		procInfo.addressMask = 0xFFFF;
		procInfo.stackOffset = 0xFFFF;
		procInfo.opcodeWidth = 16;
		procInfo.maxOpwords = 3;
		procInfo.maxAsmLineLength = 14;

		regInfo = sRegInfo;
	}

	override uint Reset()
	{
//		registers = Registers.init;
		startAddress = PC;

		return super.Reset();
	}

	override void SetProgramCounter(uint pc) nothrow
	{
		PC = cast(ushort)pc;
	}

	override int Execute(int numCycles, uint breakConditions)
	{
		int remainingCycles = numCycles;
		while(remainingCycles > 0)
		{
			// allow the debugger to step the cpu
			if(machine.Dbg.BeginStep(this, PC))
				break;

			static if(EnableDissassembly)
			{
				// log the instruction stream
				DisassembledOp disOp;
				bool bDisOpValid = false;
				uint pc = PC;
				if(bLogExecution)
					bDisOpValid = !!DisassembleOpcode(PC, &disOp);
			}

//			TRACK_OPCODE(registers.r[7]);
			ushort opcode = memmap.Read16_BE_Aligned(PC++);

			// decode the instruction
			Instruction instruction = decode(opcode);

			ulong cc = cycleCount;

			Word a, b;
			if (instruction.opcode != Instruction.Opcode.NonBasic) {
				cycleCount += cycles(instruction);
				a = read(instruction.a);
				b = read(instruction.b);
			} else {
				a = read(instruction.a);
				assert(instruction.nonbasic == Instruction.NonBasicOpcode.JSR);
				cycleCount += 2 + cycles(instruction.a);
			}

			final switch (instruction.opcode) with (Instruction.Opcode) {
				case NonBasic:  // This just does JSR for now, as it's the only non-basic OP.
					memmap.Write16_BE_Aligned(--SP, PC);
					PC = a.v;
					break;
				case SET:
					if (a.p) *a.p = b.v;
					break;
				case ADD:
					if (a.p) *a.p = cast(ushort) (a.v + b.v);
					if (a.v + b.v > ushort.max) O = 0x0001;
					else O = 0;
					break;
				case SUB:
					if (a.p) *a.p = cast(ushort) (a.v - b.v);
					if (a.v - b.v > ushort.max) O = 0xFFFF;
					else O = 0;
					break;
				case MUL:
					if (a.p) *a.p = cast(ushort) (a.v * b.v);
					O = ((a.v * b.v) >> 16) & 0xFFFF;
					break;
				case DIV:
					if (b.v != 0 && a.p) {
						*a.p = cast(ushort) (a.v / b.v);
						O = ((a.v << 16) / b.v) & 0xFFFF;
					} else if (a.p) {
						*a.p = 0;
						O = 0;
					} else {
						O = 0;
					}
					break;
				case MOD:
					if (a.p) {
						if (b.v == 0) *a.p = 0;
						else *a.p = a.v % b.v;
					}
					break;
				case SHL:
					if (a.p) *a.p = cast(ushort) (a.v << b.v);
					O = ((a.v << b.v) >> 16) & 0xFFFF;
					break;
				case SHR:
					if (a.p) *a.p = cast(ushort) (a.v >> b.v);
					O = ((a.v << 16) >> b.v) & 0xFFFF;
					break;
				case AND:
					if (a.p) *a.p = cast(ushort) (a.v & b.v);
					break;
				case BOR:
					if (a.p) *a.p = cast(ushort) (a.v | b.v);
					break;
				case XOR:
					if (a.p) *a.p = cast(ushort) (a.v ^ b.v);
					break;
				case IFE:
					if (a.v != b.v) {
						Instruction i = decode(memmap.Read16_BE_Aligned(PC++));
						skip(i);
						cycleCount++;
					}
					break;
				case IFN:
					if (a.v == b.v) {
						Instruction i = decode(memmap.Read16_BE_Aligned(PC++));
						skip(i);
						cycleCount++;
					}
					break;
				case IFG:
					if (a.v <= b.v) {
						Instruction i = decode(memmap.Read16_BE_Aligned(PC++));
						skip(i);
						cycleCount++;
					}
					break;
				case IFB:
					if ((a.v & b.v) == 0) {
						Instruction i = decode(memmap.Read16_BE_Aligned(PC++));
						skip(i);
						cycleCount++;
					}
					break;
			}

			static if(EnableDissassembly)
			{
				if(bDisOpValid)
					WriteToLog(&disOp);
			}

			remainingCycles -= cast(int)(cycleCount - cc);
			++opCount;
		}

		// return the number of cycles actually executed
		return numCycles - remainingCycles;
	}

	override uint GetRegisterValue(int reg)
	{
		if(reg < 11)
			return r[reg];
		return -1;
	}

	override void SetRegisterValue(int reg, uint value)
	{
		if(reg < 11)
			r[reg] = cast(ushort)value;
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
	//	Registers registers;
	union
	{
		ushort r[11];

		struct
		{
			ushort A, B, C, X, Y, Z, I, J; // General purpose registers.
			ushort PC; // Program counter.
			ushort SP; // Stack pointer.
			ushort O;  // Overflow.
		}
	}

	ushort[0x10000] memory;

	Instruction decode(ushort op) pure @safe
	{
		Instruction instruction;

		instruction.opcode = cast(Instruction.Opcode) (op & 0b000000_000000_1111);
		if(instruction.opcode == Instruction.Opcode.NonBasic)
		{
			if (((op & 0b000000_111111_0000) >> 4) != 0x01)
			{
				throw new Exception("no support for any non-basic opcode except for JSR.");
			}
			instruction.nonbasic = Instruction.NonBasicOpcode.JSR;
		}
		else
		{
			ushort a = (op & 0b000000_111111_0000) >> 4;
			instruction.a = cast(Instruction.Value) a;
		}

		ushort b = (op & 0b111111_000000_0000) >> 10;
		instruction.b = cast(Instruction.Value) b;

		return instruction;
	}

    protected final Word read(in Instruction.Value location) pure @safe
    {
        switch (location) with (Instruction) {
			case Value.A: return Word(A, &A);
			case Value.B: return Word(B, &B);
			case Value.C: return Word(C, &C);
			case Value.X: return Word(X, &X);
			case Value.Y: return Word(Y, &Y);
			case Value.Z: return Word(Z, &Z);
			case Value.I: return Word(I, &I);
			case Value.J: return Word(J, &J);
			case Value.LDA: return Word(memory[A], &memory[A]);
			case Value.LDB: return Word(memory[B], &memory[B]);
			case Value.LDC: return Word(memory[C], &memory[C]);
			case Value.LDX: return Word(memory[X], &memory[X]);
			case Value.LDY: return Word(memory[Y], &memory[Y]);
			case Value.LDZ: return Word(memory[Z], &memory[Z]);
			case Value.LDI: return Word(memory[I], &memory[I]);
			case Value.LDJ: return Word(memory[J], &memory[J]);
			case Value.LDPCA: PC++; return Word(memory[memory[PC] + A], &memory[memory[PC] + A]);
			case Value.LDPCB: PC++; return Word(memory[memory[PC] + B], &memory[memory[PC] + B]);
			case Value.LDPCC: PC++; return Word(memory[memory[PC] + C], &memory[memory[PC] + C]);
			case Value.LDPCX: PC++; return Word(memory[memory[PC] + X], &memory[memory[PC] + X]);
			case Value.LDPCY: PC++; return Word(memory[memory[PC] + Y], &memory[memory[PC] + Y]);
			case Value.LDPCZ: PC++; return Word(memory[memory[PC] + Z], &memory[memory[PC] + Z]);
			case Value.LDPCI: PC++; return Word(memory[memory[PC] + I], &memory[memory[PC] + I]);
			case Value.LDPCJ: PC++; return Word(memory[memory[PC] + J], &memory[memory[PC] + J]);
			case Value.POP: auto w = Word(memory[SP], &memory[SP]); SP++; return w;
			case Value.PEEK: return Word(memory[SP], &memory[SP]);
			case Value.PUSH: --SP; return Word(memory[SP], &memory[SP]);
			case Value.SP: return Word(SP, &SP);
			case Value.PC: return Word(PC, &PC);
			case Value.O: return Word(O, &O);
			case Value.LDNXT: auto w = Word(memory[memory[PC]], &memory[memory[PC]]); PC++; return w;
			case Value.NXT: return Word(memory[PC++], null);
			default:
				assert(location >= Value.LITERAL);
				return Word(location - Value.LITERAL, null);
        }
        // Never reached.
    }

    /// Advance the PC past the given instruction.
    protected final void skip(ref const Instruction i) @safe
    {
        if (i.opcode != Instruction.Opcode.NonBasic) {
            read(i.a);
            read(i.b);
        } else {
            assert(i.nonbasic == Instruction.NonBasicOpcode.JSR);
            read(i.a);
            cycleCount += 2 + cycles(i.a);
        }
    }
}

/// A locations value and where to write to if you can write to it.
struct Word
{
    ushort v;
    ushort* p;
}

/// Convert word 'op' into an Instruction.
Instruction decode(ushort op) pure @safe
{
    Instruction instruction;

    instruction.opcode = cast(Instruction.Opcode) (op & 0b000000_000000_1111);
    if (instruction.opcode == Instruction.Opcode.NonBasic) {
        if (((op & 0b000000_111111_0000) >> 4) != 0x01) {
            throw new Exception("no support for any non-basic opcode except for JSR.");
        }
        instruction.nonbasic = Instruction.NonBasicOpcode.JSR;
        ushort a = (op & 0b111111_000000_0000) >> 10;
        instruction.a = cast(Instruction.Value) a;
        return instruction;
    } else {
        ushort a = (op & 0b000000_111111_0000) >> 4;
        instruction.a = cast(Instruction.Value) a;
    }

    ushort b = (op & 0b111111_000000_0000) >> 10;
    instruction.b = cast(Instruction.Value) b;

    return instruction;
}

immutable int[Instruction.Opcode.max+1] opcycles = [
	-1,   // NonBasic
    1,   // SET
    2,   // ADD
    2,   // SUB
    2,   // MUL
    3,   // DIV
    3,   // MOD
    2,   // SHL
    2,   // SHR
    1,   // AND
    1,   // BOR
    1,   // XOR
    2,   // IFE
    2,   // IFN
    2,   // IFG
    2,   // IFB
];

/// How many cycles does val take to look up?
int cycles(in Instruction.Value val) pure @safe
{
    return ((val > 0x10 && val <= 0x17) || val == 0x1E || val == 0x1F) ? 1 : 0;
}

/// How many cycles will instruction take (not counting failed IF ops)?
int cycles(ref const Instruction instruction) pure @safe
{
    return opcycles[instruction.opcode] + cycles(instruction.a) + cycles(instruction.b);
}

/**
* Represents a single DCPU-16 instruction.
*/
struct Instruction
{
    enum Opcode : ubyte
    {
        NonBasic = 0x0,
        SET,
        ADD,
        SUB,
        MUL,
        DIV,
        MOD,
        SHL,
        SHR,
        AND,
        BOR,
        XOR,
        IFE,
        IFN,
        IFG,
        IFB
    }

    enum NonBasicOpcode : ubyte
    {
        JSR = 0x01
    }

    enum Value : ubyte
    {
        A = 0x0,  // register
        B,
        C,
        X,
        Y,
        Z,
        I,
        J,
        LDA,  // [register]
        LDB,
        LDC,
        LDX,
        LDY,
        LDZ,
        LDI,
        LDJ,
        LDPCA,  // [next word + register]
        LDPCB,
        LDPCC,
        LDPCX,
        LDPCY,
        LDPCZ,
        LDPCI,
        LDPCJ,
        POP,
        PEEK,
        PUSH,
        SP,
        PC,
        O,
        LDNXT,  // [next word]
        NXT,  // next word (literal)
        LITERAL  // literal value
    }

    static assert(Value.LITERAL == 0x20);

    Opcode opcode;  /// The opcode of the instruction.
    NonBasicOpcode nonbasic;  /// If opcode is NonBasic, then this is filled in.
    Value a;  /// First value evaluated.
    Value b;  /// Second value evaluated.
}

immutable RegisterInfo[] sRegInfo =
[
	RegisterInfo( "A", 16, 0, null ),
	RegisterInfo( "B", 16, 0, null ),
	RegisterInfo( "C", 16, 0, null ),
	RegisterInfo( "X", 16, 0, null ),
	RegisterInfo( "Y", 16, 0, null ),
	RegisterInfo( "Z", 16, 0, null ),
	RegisterInfo( "I", 16, 0, null ),
	RegisterInfo( "J", 16, 0, null ),
	RegisterInfo( "PC", 16, RegisterInfo.Flags.ProgramCounter, null ),
	RegisterInfo( "SP", 16, RegisterInfo.Flags.StackPointer, null ),
	RegisterInfo( "O", 16, 0, null )
];

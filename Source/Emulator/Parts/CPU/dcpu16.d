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

	uint Reset()
	{
//		registers = Registers.init;
		startAddress = PC;

		return super.Reset();
	}

	void SetProgramCounter(uint pc) nothrow
	{
		PC = cast(ushort)pc;
	}

	int Execute(int numCycles, uint breakConditions)
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

			if (instruction.opcode != Instruction.Opcode.NonBasic)
				cycleCount += cycles(instruction);

			bool ald, bld;
			ushort a = read(instruction.a);
			ushort b = read(instruction.b);
			final switch (instruction.opcode) with (Instruction.Opcode)
			{
				case NonBasic:
					assert(instruction.nonbasic == Instruction.Opcode.NonBasic);
					cycleCount += 2 + cycles(instruction.a) + cycles(instruction.b);
					memmap.Write16_BE_Aligned(--SP, PC);
					PC = A;
					break;
				case SET:
					write(instruction.a, a, b);
					break;
				case ADD:
					write(instruction.a, a, cast(ushort) (a + b));
					if (a + b > ushort.max) O = 0x0001;
					else O = 0;
					break;
				case SUB:
					write(instruction.a, a, cast(ushort) (a - b));
					if (a - b > ushort.max) O = 0xFFFF;
					else O = 0;
					break;
				case MUL:
					write(instruction.a, a, cast(ushort) (a * b));
					O = ((a * b) >> 16) & 0xFFFF;
					break;
				case DIV:
					if (b != 0) {
						write(instruction.a, a, cast(ushort) (a / b));
						O = ((a << 16) / b) & 0xFFFF;
					} else {
						write(instruction.a, a, 0);
						O = 0;
					}
					break;
				case MOD:
					if (b == 0) write(instruction.a, a, 0);
					else write(instruction.a, a, a % b);
					break;
				case SHL:
					write(instruction.a, a, cast(ushort) (a << b));
					O = ((a << b) >> 16) & 0xFFFF;
					break;
				case SHR:
					write(instruction.a, a, cast(ushort) (a >> b));
					O = ((a << 16) >> b) & 0xFFFF;
					break;
				case AND:
					write(instruction.a, a, cast(ushort) (a & b));
					break;
				case BOR:
					write(instruction.a, a, cast(ushort) (a | b));
					break;
				case XOR:
					write(instruction.a, a, cast(ushort) (a ^ b));
					break;
				case IFE:
					if (a != b) {
						PC++;
						cycleCount++;
					}
					break;
				case IFN:
					if (a == b) {
						PC++;
						cycleCount++;
					}
					break;
				case IFG:
					if (a <= b) {
						PC++;
						cycleCount++;
					}
					break;
				case IFB:
					if ((a & b) == 0) {
						PC++;
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

	uint GetRegisterValue(int reg)
	{
		if(reg < 11)
			return r[reg];
		return -1;
	}

	void SetRegisterValue(int reg, uint value)
	{
		if(reg < 11)
			r[reg] = cast(ushort)value;
	}

	int DisassembleOpcode(uint address, DisassembledOp* pOpcode)
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

	protected final void write(in Instruction.Value location, in ushort p, in ushort val)
    {
        switch(location) with (Instruction)
		{
			case Value.A: A = val; break;
			case Value.B: B = val; break;
			case Value.C: C = val; break;
			case Value.X: X = val; break;
			case Value.Y: Y = val; break;
			case Value.Z: Z = val; break;
			case Value.I: I = val; break;
			case Value.J: J = val; break;
			case Value.LDA: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDB: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDC: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDX: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDY: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDZ: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDI: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDJ: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDPCA: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDPCB: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDPCC: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDPCX: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDPCY: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDPCZ: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDPCI: memmap.Write16_BE_Aligned(p, val); break;
			case Value.LDPCJ: memmap.Write16_BE_Aligned(p, val); break;
			case Value.POP: memmap.Write16_BE_Aligned(p, val); break;
			case Value.PEEK: memmap.Write16_BE_Aligned(p, val); break;
			case Value.PUSH: memmap.Write16_BE_Aligned(p, val); break;
			case Value.SP: SP = val; break;
			case Value.PC: PC = val; break;
			case Value.O: O = val; break;
			case Value.LDNXT: memmap.Write16_BE_Aligned(p, val); break;
			default: break;
        }
    }

    /**
	* Read word at location.
	* If the value uses indirection, the last layer is not performed --
	* that's left up to write.
	* See: write
	*/
    protected final ushort read(in Instruction.Value location)
    {
        switch (location) with (Instruction)
		{
			case Value.A: return A;
			case Value.B: return B;
			case Value.C: return C;
			case Value.X: return X;
			case Value.Y: return Y;
			case Value.Z: return Z;
			case Value.I: return I;
			case Value.J: return J;
			case Value.LDA: return A;
			case Value.LDB: return B;
			case Value.LDC: return C;
			case Value.LDX: return X;
			case Value.LDY: return Y;
			case Value.LDZ: return Z;
			case Value.LDI: return I;
			case Value.LDJ: return J;
			case Value.LDPCA: return cast(ushort) (memmap.Read16_BE_Aligned(PC++) + A);
			case Value.LDPCB: return cast(ushort) (memmap.Read16_BE_Aligned(PC++) + B);
			case Value.LDPCC: return cast(ushort) (memmap.Read16_BE_Aligned(PC++) + C);
			case Value.LDPCX: return cast(ushort) (memmap.Read16_BE_Aligned(PC++) + X);
			case Value.LDPCY: return cast(ushort) (memmap.Read16_BE_Aligned(PC++) + Y);
			case Value.LDPCZ: return cast(ushort) (memmap.Read16_BE_Aligned(PC++) + Z);
			case Value.LDPCI: return cast(ushort) (memmap.Read16_BE_Aligned(PC++) + I);
			case Value.LDPCJ: return cast(ushort) (memmap.Read16_BE_Aligned(PC++) + J);
			case Value.POP: return SP++;
			case Value.PEEK: return SP;
			case Value.PUSH: return --SP;
			case Value.SP: return SP;
			case Value.PC: return PC;
			case Value.O: return O;
			case Value.LDNXT: return memmap.Read16_BE_Aligned(PC++);
			case Value.NXT: return PC++;
			default:
				assert(location >= Value.LITERAL);
				return location - Value.LITERAL;
        }
        // Never reached.
    }
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

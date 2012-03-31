module demu.parts.part;

import demu.machine;
import demu.memmap;
import demu.util;

import std.string;
import std.conv;

enum Endian
{
	Little,
	Big
}

enum LogTarget
{
	Any = -1,

	File = 0,
	Console,
	Debugger,
	User,

	NumTargets
}

struct RegisterInfo
{
	enum Flags
	{
		ProgramCounter = bit!0,
		StackPointer = bit!1,
		FlagsRegister = bit!2,
		ReadOnly = bit!3,
		WriteOnly = bit!4
	}

	string name;
	int width; // in bits
	uint flags;
	string flagsNames;
}

enum SymbolType
{
	MemoryAddress,
	CodeLabel,
}

enum SymbolDataType
{
	Int,
	Bcd,
}

struct AddressInfo
{
	uint address;
	string readLabel;
	string writeLabel;

	SymbolType type;

	SymbolDataType dataType;
	int dataWidth;

	@property string CodeLabel() const nothrow { return type == SymbolType.CodeLabel ? readLabel : null; }
	@property string ReadLabel() const nothrow { return readLabel; }
	@property string WriteLabel() const nothrow { return writeLabel ? writeLabel : readLabel; }
}

struct ProcessorInfo
{
	string name;
	string processorFamily;

	Endian endian;

	int addressWidth; // in bits
	uint addressMask;
	uint portMask;
	uint stackOffset;

	int opcodeWidth; // width of opcode words in bits
	int maxOpwords;  // maximum number of opwords in an instruction
	int maxAsmLineLength; // maximum length of a line in asm
}

struct DisassembledOp
{
	enum Flags
	{
		EndOfSequence = bit!0,
		Branch = bit!1,
		Jump = bit!2,
		Return = bit!3,
		Load = bit!4,
		Store = bit!5,
		Conditional = bit!6,
		Invalid = bit!7
	}

	struct Arg
	{
		enum Type
		{
			Register,
			Address,
			ReadAddress,
			WriteAddress,
			ReadPort,
			WritePort,
			JumpTarget,
			Immediate, // hex
			Constant,  // signed int
			Condition
		}

		enum int MaxLength = 32-5;
		StaticString!MaxLength arg;
		ubyte type;
		uint value;
	}

	StaticString!40 lineTemplate;
	StaticString!16 instructionName;
	uint programCode[8];
	uint programOffset;
	ubyte pcWords;
	ubyte numArgs;
	ubyte flags;
	ubyte reserved;
	Arg args[8];

	char[] GetAsm(char[] output, bool bShowProgramCode, Part part = null)
	{
		// this should be enough...
		const(char)[][8] pArgs;

		// look up args
		foreach(a; 0..numArgs)
		{
			if(part)
			{
				if(args[a].type == Arg.Type.ReadAddress || args[a].type == Arg.Type.Address)
				{
					// attempt to locate an address name
					pArgs[a] = part.GetReadSymbol(AtoI!16(args[a].arg));
				}
				else if(args[a].type == Arg.Type.WriteAddress)
				{
					// attempt to locate an address name
					pArgs[a] = part.GetWriteSymbol(AtoI!16(args[a].arg));
				}
				if(args[a].type == Arg.Type.ReadPort)
				{
					// attempt to locate an address name
					pArgs[a] = part.GetPortReadSymbol(AtoI!16(args[a].arg));
				}
				else if(args[a].type == Arg.Type.WritePort)
				{
					// attempt to locate an address name
					pArgs[a] = part.GetPortWriteSymbol(AtoI!16(args[a].arg));
				}
				else if(args[a].type == Arg.Type.JumpTarget)
				{
					// attempt to locate a label for target
					pArgs[a] = part.GetReadSymbol(AtoI!16(args[a].arg));
				}
			}

			if(!pArgs[a])
				pArgs[a] = args[a].arg;
		}

		return sformat(output, lineTemplate.data, instructionName.data, pArgs[0], pArgs[1], pArgs[2], pArgs[3], pArgs[4], pArgs[5], pArgs[6], pArgs[7]);
	}

	char[] GetProgramCode(char[] output, int opwordWidth)
	{
		opwordWidth = (opwordWidth + 3) >> 2;
		int bytes;
		foreach(a; 0..pcWords)
			bytes += sformat(output[bytes..$], a > 0 && opwordWidth > 2 ? " %0*X" : "%0*X", opwordWidth, programCode[a]).length;
		return output[0..bytes];
	}

	char[] GetString(char[] output, int opcodeWidth)
	{
		int bytes;
		bytes += sformat(output, "%X:%s:%s:%X:", programOffset, lineTemplate, instructionName, flags).length;
		bytes += GetProgramCode(output[bytes..$], opcodeWidth).length;
		foreach(a; 0..numArgs)
			bytes += sformat(output[bytes..$], ";%s:%u:%u", args[a].arg, args[a].type, args[a].value).length;
		return output[0..bytes];
	}
}

struct StackFrame
{
	uint jumpTarget;
	uint returnPointer;
}

class Part
{
	enum Feature
	{
		Memory = bit!0,
		Registers = bit!1,
		Stack = bit!2,
		Code = bit!3,
		Viewport = bit!4
		//IOPorts = bit!5, // Useful?
		//Sound = bit!6    // Useful?
	}

	this(Machine machine, string name, uint features)
	{
		this.machine = machine;
		this.name = name;
		this.features = features;

		id = machine.AddPart(this);
	}

	Machine GetMachine() nothrow { return machine; }

	@property string Name() const nothrow { return name; }
	@property int ID() const nothrow { return id; }

	@property void Features(uint features) nothrow { this.features = features; }
	@property uint Features() const nothrow { return features; }
	bool HasFeature(Feature feature) const nothrow { return (features & feature) != 0; }

	// memory
	@property void MemoryMap(MemMap memmap) nothrow
	{
		this.memmap = memmap;
		if(memmap)
			features |= Feature.Memory;
		else
			features &= ~Feature.Memory;
	}
	@property MemMap MemoryMap() nothrow { return memmap; }

	void RegisterSymbols(const(AddressInfo)[] addressInfo)
	{
		foreach(ref ai; addressInfo)
			symbolTable[ai.address] = &ai;
	}
	const(AddressInfo)* GetSymbol(uint address)
	{
		const(AddressInfo)** ppAddr = address in symbolTable;
		return ppAddr ? *ppAddr : null;
	}
	string GetReadSymbol(uint address)
	{
		const(AddressInfo)* pAddr = GetSymbol(address);
		return pAddr ? symbolTable[address].readLabel : null;
	}
	string GetWriteSymbol(uint address)
	{
		const(AddressInfo)* pAddr = GetSymbol(address);
			return pAddr ? (pAddr.writeLabel ? pAddr.writeLabel : pAddr.readLabel) : null;
	}

	void RegisterPortSymbols(const(AddressInfo)[] addressInfo)
	{
		foreach(ref ai; addressInfo)
			portSymbolTable[ai.address] = &ai;
	}
	const(AddressInfo)* GetPortSymbol(uint address)
	{
		const(AddressInfo)** ppAddr = address in portSymbolTable;
		return ppAddr ? *ppAddr : null;
	}
	string GetPortReadSymbol(uint address)
	{
		const(AddressInfo)* pAddr = GetPortSymbol(address);
		return pAddr ? pAddr.ReadLabel : null;
	}
	string GetPortWriteSymbol(uint address)
	{
		const(AddressInfo)* pAddr = GetPortSymbol(address);
		return pAddr ? pAddr.WriteLabel : null;
	}

	// registers
	const(RegisterInfo)[] GetRegisterInfo() { return regInfo[]; }
	char[] GetRegisterValueAsString(char[] buffer, int reg, bool bShowFlags = true)
	{
		uint value = GetRegisterValue(reg);

		if(regInfo)
		{
			const RegisterInfo* r = &regInfo[reg];

			char* pBuffer = buffer.ptr;
			if(r.flags & RegisterInfo.Flags.FlagsRegister)
			{
				assert(r.width <= buffer.length, "Buffer too small!");

				int bit = 1<<(r.width-1);
				foreach(a; 0..r.width)
				{
					pBuffer[a] = (value & bit) ? r.flagsNames[a] : '.';
					bit >>= 1;
				}
				return buffer[0..r.width];
			}
			else
			{
				int digits = (r.width+3) >> 2;
				return sformat(buffer, "$%0*X", digits, value);
			}
		}
		else
			return sformat(buffer, "$%X", value);
	}

	/+virtual+/ uint GetRegisterValue(int reg) { return 0; }
	/+virtual+/ void SetRegisterValue(int reg, uint value) {}

	// processor
	/+virtual+/ @property const(ProcessorInfo)* ProcInfo() const nothrow { return null; }

	// processor
	static if(EnableDebugger)
	{
		void DisassembleCode(uint address, int numLines, bool bRecurse, bool bSendToDebugger)
		{
			static char[2048] codeBuffer;
			static int codeBytes = 0;

			const ProcessorInfo* procInfo = ProcInfo;

			int numInvalid = 0;

			while(numLines--)
			{
				// we may overflow the memory space
				address &= procInfo.addressMask;

				// check we haven't disassembled this code before...
				/+
				int i = address >> 5;
				uint bit = 1 << (address&0x1F);

				if(codeDisassembled[i] & bit)
					break;

				codeDisassembled[i] |= bit;
				+/

				DisassembledOp disasm = null;
				int opBytes = DisassembleOpcode(address, &disasm);

				if(!opBytes && numInvalid < 1)
				{
					// if we reached an invalid instruction, decode as data
					disasm.programOffset = address;
					disasm.lineTemplate = "%s %s";

					// since different processors have different width opword widths
					uint opword = 0;
					switch(procInfo.opcodeWidth)
					{
						case 16:
							disasm.instructionName = ".DW";
							if(procInfo.endian == Endian.Big)
								opword = memmap.Read16_BE(address);
							else
								opword = memmap.Read16_LE(address);
							break;
						case 10:
							// ** HACK FOR INTV **
							disasm.instructionName = ".DATA";
							opword = memmap.Read16_BE_Aligned(address);
							break;
						case 8:
							disasm.instructionName = ".DB";
							opword = memmap.Read8(address);
							break;
						default:
							assert(false, "Unsupported opcode width");
							break;
					}
					opBytes = procInfo.opcodeWidth >> 8;

					// fill out the data as an arg
					sformat(disasm.args[0].arg, "#$%0*X", (procInfo.opcodeWidth + 3) / 4, opword);
					disasm.args[0].type = DisassembledOp.Arg.Type.Immediate;
					disasm.args[0].value = opword;
					disasm.programCode[0] = opword;
					disasm.pcWords = 1;
					disasm.numArgs = 1;
					disasm.flags = DisassembledOp.Flags.Invalid;

					++numInvalid;
				}

				if(opBytes)
				{
					address += opBytes;

					if(bSendToDebugger)
					{
						if(codeBytes)
							code[codeBytes++] = '\n';

						codeBytes += disasm.GetString(&code[codeBytes], 2048-codeBytes, procInfo.opcodeWidth);

						if(codeBytes >= 1920)
						{
							SendDebugMessage("CODE", code);
							codeBytes = 0;
						}
					}

					foreach(a; 0..disasm.numArgs)
					{
						if(disasm.args[a].argType == DisassembledOp.Arg.JumpTarget)
						{
							if(codeBytes)
							{
								SendDebugMessage("CODE", code);
								codeBytes = 0;
							}

							DisassembleCode(disasm.args[a].value, numLines, true, bSendToDebugger);
						}
					}
				}

				if(!opBytes || (disasm.flags & DisassembledOp.EndOfSequence))
					break;
			}

			if(codeBytes)
			{
				SendDebugMessage("CODE", code);
				codeBytes = 0;
			}
		}

		void InvalidateDisassembly(uint start, uint length)
		{
			memset(codeDisassembled + (start >> 5), 0, sizeof(codeDisassembled[0]) * ((length+31) >> 5));

			char args[32];
			sformat(args, "%X:%X", start, length);
			SendDebugMessage("INVALIDATECODE", args);
		}

		void SendDebugMessage(string msg, string data)
		{
			// send debug message
		}
	}

	// debug + logging
	void LogMessage(const(char)[] message)
	{
		// write to various log outputs

		// perhaps we have an option for CPU's to write to their own log file?
		bool bWriteToOwnLog = false;
		if(bWriteToOwnLog)
		{
			//...
		}

		static if(EnableDebugger)
		{
			if(logTargets[LogTarget.Debugger])
				SendDebugMessage("LOG", pMessage);
		}

		// prepend the component name...
		const(char)[] msg = message;
/*
		int len = 0;
		const char* pLine = strtok((char*)pMessage, "\n");
		while(pLine)
		{
			len += sprintf_s(message + len, sizeof(message) - len, "%s: %s\n", name, pLine);
			pLine = strtok(NULL, "\n");
		}
*/

		if(!bWriteToOwnLog)
		{
			if(logTargets[LogTarget.File])
				machine.LogMessage(msg, LogTarget.File);
		}

		if(logTargets[LogTarget.Console])
			machine.LogMessage(msg, LogTarget.Console);
	}

protected:
	Machine machine;

	string name;
	int id;

	uint features;
	uint flags;

	// memory feature
	MemMap memmap;

	const(AddressInfo)*[uint] symbolTable;
	const(AddressInfo)*[uint] portSymbolTable;

	// registers feature
	const(RegisterInfo)[] regInfo;
	const(int)[] displayRegs;

	// processor feature
	uint startAddress;

	static if(EnableDissassembly)
	{
		/+virtual+/ int DisassembleOpcode(uint address, DisassembledOp* pOpcode) { return false; }
	}

	// stack feature
	StackFrame[] stack;

	// viewport feature

	// IO/Port feature

	// sound feature

	// debug + logging
	int[LogTarget.NumTargets] logTargets;
}

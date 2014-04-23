module demu.emulator.parts.cpu.cp1600;

import demu.emulator.machine;
import demu.emulator.memmap;
import demu.emulator.parts.part;
import demu.emulator.parts.processor;

import std.string;

class CP1600 : Processor
{
	enum Version
	{
		CP1600,
		CP1610
	}

	this(Machine machine, string name, MemMap memmap)
	{
		super(machine, name, Part.Feature.Stack | Part.Feature.Code | Part.Feature.Registers);
		MemoryMap = memmap;

		procInfo.name = sProcessorName[Version.CP1610];
		procInfo.processorFamily = "CP1600";
		procInfo.endian = Endian.Little;
		procInfo.addressWidth = 16;
		procInfo.addressMask = 0xFFFF;
		procInfo.stackOffset = 0;
		procInfo.opcodeWidth = 10;
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
			// allow the debugger to step the cpu
//			if(DebugBeginStep(registers.r[7]))
//				break;

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
			Instruction instruction = cast(Instruction)DecodeInstruction(opcode);
			AddressModes am = GetAddressMode(instruction, opcode);

			ulong cc = cycleCount;
			cycleCount += sOpcodeTable[instruction].cc;
			waitCycles = 0;

			int address = 0;
			int operand = 0;
			int target = 0;
			switch(am) with(AddressModes)
			{
				case RegisterImmediate:
					target = opcode & 3;
					if(opcode & 4)
						operand = 2, cycleCount += 2;
					else
						operand = 1;
					break;
				case RegisterRegister:
					operand = registers.r[(opcode >> 3) & 7];
					goto case;
				case Register:
					target = opcode & 7;
					break;
				case Direct:
					operand = memmap.Read16_BE_Aligned(registers.r[7]++);
					address = (opcode & 0x20) ? registers.r[7] - operand - 1 : registers.r[7] + operand;
					break;
				case DirectRegister:
					address = memmap.Read16_BE_Aligned(registers.r[7]++);
					if(instruction != Instruction.MVO)
						operand = memmap.Read16_BE_Aligned(address);
					target = opcode & 7;
					cycleCount += 2;
					break;
				case Indirect:
				case Immediate:
				{
					// get the source register
					int reg = (opcode >> 3) & 7;

					int increment = 0;

					// if the source is the stack pointer, handle the pre-decrement...
					if(reg == 6)
					{
						if(instruction == Instruction.MVO)
							increment = 1;
						else
						{
							cycleCount += 3;
							--registers.r[6];
						}
					}
					else if(reg == 4 || reg == 5 || reg == 7)
					{
						// auto-increment registers
						increment = 1;
					}

					// get the address
					address = registers.r[reg];

					if(instruction != Instruction.MVO)
					{
						// look up the value
						if(registers.swd & SR_DoubleByteData)
						{
							cycleCount += 2;
							registers.r[reg] += increment;
							operand = cast(int)(memmap.Read16_BE_Aligned(address) & 0xFF);
							operand |= cast(int)(memmap.Read16_BE_Aligned(address+increment) & 0xFF) << 8;
						}
						else
							operand = memmap.Read16_BE_Aligned(address);
					}

					registers.r[reg] += increment;

					// get the target register
					target = opcode & 7;
					break;
				}
//				case Implied:
//					break;
				default:
					break;
			}

			// reset Double Byte Data flag
			registers.swd &= ~SR_DoubleByteData;

			switch(instruction) with(Instruction)
			{
				case HLT:
				{
//					machine.DebugBreak("HLT instruction reached", BR_HaltInstruction);
					assert(false, "Halt instruction reached!");
				}
				case SDBD:
					registers.swd |= SR_DoubleByteData;
					break;
				case EIS:
					registers.swd |= SR_InterruptEnable;
					break;
				case DIS:
					registers.swd &= ~SR_InterruptEnable;
					break;
				case J:
				{
					// decode target address
					address = memmap.Read16_BE_Aligned(registers.r[7]++);
					int i = address & 0x3;
					int r = (address >> 8) & 0x3;
					address = ((address & 0xFC) << 8) | memmap.Read16_BE_Aligned(registers.r[7]++) & 0x3FF;

					// store return address
					if(r < 3)
					{
						registers.r[4 + r] = registers.r[7];
//						DebugJumpToSub(registers.r[7], address, -1);
					}

					// perform jump
					registers.r[7] = cast(ushort)address;

					// update the interrupt flag
					if(i == 1)
						registers.swd |= SR_InterruptEnable;
					else if(i == 2)
						registers.swd &= ~SR_InterruptEnable;
					break;
				}
				case TCI:
					// strobe the TCI output pin of the CPU
					// Intellivision doesn't appear to connect this pin to anything useful, safe to ignore?
					break;
				case CLRC:
					registers.swd &= ~SR_Carry;
					break;
				case SETC:
					registers.swd |= SR_Carry;
					break;
				case INCR:
					++registers.r[target];
					FLAGSZ(registers.r[target]);
					break;
				case DECR:
					--registers.r[target];
					FLAGSZ(registers.r[target]);
					break;
				case COMR:
					registers.r[target] = ~registers.r[target];
					FLAGSZ(registers.r[target]);
					break;
				case NEGR:
				{
					uint result = (registers.r[target]^0xFFFF) + 1;
					FLAGSZC(result);
					if(registers.r[target] == 0x8000)
						registers.swd |= SR_Overflow;
					registers.r[target] = cast(ushort)result;
					break;
				}
				case ADCR:
				{
					uint result = registers.r[target];
					if(registers.swd & SR_Carry)
						++result;
					FLAGSZC(result);
					if(~registers.r[target] & result & 0x8000)
						registers.swd |= SR_Overflow;
					registers.r[target] = cast(ushort)result;
					break;
				}
				case GSWD:
					registers.r[target] = registers.swd & 0xF0F0;
					break;
				case NOP:
					break;
				case SIN:
					// this instruction has no use on the intellivison as the CPUs' PCIT pin is not connected.
					// Program Counter Inhibit / Trap
					break;
				case RSWD:
					registers.swd = (((registers.r[target] & 0xFF) | (registers.r[target] << 8)) & 0xF0F0) | (registers.swd & 0xF);
					break;
				case SWAP:
					if(operand == 1)
						registers.r[target] = cast(ushort)((registers.r[target] >> 8) | (registers.r[target] << 8));
					else
					{
						registers.r[target] = cast(ushort)((registers.r[target] & 0xFF) | (registers.r[target] << 8));
						cycleCount += 2;
					}
					FLAGSbZ(registers.r[target]);
					break;
				case SLL:
					registers.r[target] <<= operand;
					FLAGSZ(registers.r[target]);
					break;
				case RLC:
				{
					int result;
					if(operand == 1)
					{
						result = registers.r[target] << 1 | ((registers.swd >> 12) & 0x1);
						registers.swd = (registers.swd & ~SR_Carry) | ((result & 0x10000) ? SR_Carry : 0);
					}
					else
					{
						result = registers.r[target] << 2 | ((registers.swd >> 11) & 0x2) | ((registers.swd >> 13) & 0x1);
						registers.swd = (registers.swd & ~(SR_Carry|SR_Overflow)) | ((result & 0x20000) ? SR_Carry : 0) | ((result & 0x10000) ? SR_Overflow : 0);
					}
					registers.r[target] = cast(ushort)result;
					FLAGSZ(registers.r[target]);
					break;
				}
				case SLLC:
				{
					int result = registers.r[target] << operand;
					if(operand == 1)
						registers.swd = (registers.swd & ~SR_Carry) | ((result & 0x10000) ? SR_Carry : 0);
					else
						registers.swd = (registers.swd & ~(SR_Carry|SR_Overflow)) | ((result & 0x20000) ? SR_Carry : 0) | ((result & 0x10000) ? SR_Overflow : 0);
					registers.r[target] = cast(ushort)result;
					FLAGSZ(registers.r[target]);
					break;
				}
				case SLR:
					registers.r[target] >>= operand;
					FLAGSbZ(registers.r[target]);
					break;
				case SAR:
					if(operand == 1)
						registers.r[target] = (registers.r[target] >> 1) | (registers.r[target] & 0x8000);
					else
						registers.r[target] = (registers.r[target] >> 2) | (registers.r[target] & 0x8000) | ((registers.r[target] & 0x8000) >> 1);
					FLAGSbZ(registers.r[target]);
					break;
				case RRC:
				{
					int result = registers.r[target];
					if(operand == 1)
					{
						result |= (registers.swd & SR_Carry) ? 0x10000 : 0;
						registers.swd = (registers.swd & ~SR_Carry) | ((result & 0x1) ? SR_Carry : 0);
					}
					else
					{
						result |= ((registers.swd & SR_Carry) ? 0x10000 : 0) | ((registers.swd & SR_Overflow) ? 0x20000 : 0);
						registers.swd = (registers.swd & ~(SR_Carry|SR_Overflow)) | ((result & 0x1) ? SR_Carry : 0) | ((result & 0x2) ? SR_Overflow : 0);
					}
					registers.r[target] = cast(ushort)(result >> operand);
					FLAGSbZ(registers.r[target]);
					break;
				}
				case SARC:
				{
					int result = registers.r[target];
					if(operand == 1)
					{
						registers.swd = (registers.swd & ~SR_Carry) | ((registers.r[target] & 0x1) ? SR_Carry : 0);
						registers.r[target] = (registers.r[target] >> 1) | (registers.r[target] & 0x8000);
					}
					else
					{
						registers.swd = (registers.swd & ~(SR_Carry|SR_Overflow)) | ((registers.r[target] & 0x1) ? SR_Carry : 0) | ((registers.r[target] & 0x2) ? SR_Overflow : 0);
						registers.r[target] = (registers.r[target] >> 2) | (registers.r[target] & 0x8000) | ((registers.r[target] & 0x8000) >> 1);
					}
					FLAGSbZ(registers.r[target]);
					break;
				}
				case MOVR:
					registers.r[target] = cast(ushort)operand;
					if(target == 6 || target == 7)
						++cycleCount;
					FLAGSZ(registers.r[target]);
					break;
				case ADDR:
				case ADD:
				{
					uint result = registers.r[target] + cast(ushort)operand;
					FLAGSZC(result);
					if(~(registers.r[target] ^ operand) & (registers.r[target] ^ result) & 0x8000)
						registers.swd |= SR_Overflow;
					registers.r[target] = cast(ushort)result;
					break;
				}
				case SUBR:
				case SUB:
				{
//					uint result = registers.r[target] - cast(ushort)operand;
					uint result = registers.r[target] + cast(ushort)~operand + 1;
					FLAGSZC(result);
					if((registers.r[target] ^ operand) & (registers.r[target] ^ result) & 0x8000)
						registers.swd |= SR_Overflow;
					registers.r[target] = cast(ushort)result;
					break;
				}
				case CMPR:
				case CMP:
				{
//					uint result = registers.r[target] - cast(ushort)operand;
					uint result = registers.r[target] + cast(ushort)~operand + 1;
					FLAGSZC(result);
					if((registers.r[target] ^ operand) & (registers.r[target] ^ result) & 0x8000)
						registers.swd |= SR_Overflow;
					break;
				}
				case ANDR:
				case AND:
					registers.r[target] &= operand;
					FLAGSZ(registers.r[target]);
					break;
				case XORR:
				case XOR:
					registers.r[target] ^= operand;
					FLAGSZ(registers.r[target]);
					break;
				case B:
					registers.r[7] = cast(ushort)address;
					cycleCount += 2;
					break;
				case BC:
					if(registers.swd & SR_Carry)
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BOV:
					if(registers.swd & SR_Overflow)
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BPL:
					if(!(registers.swd & SR_Sign))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BEQ:
					if(registers.swd & SR_Zero)
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BLT:
					if(((registers.swd & SR_Sign) >> 2) != (registers.swd & SR_Overflow))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BLE:
					if((registers.swd & SR_Zero) || ((registers.swd & SR_Sign) >> 2) != (registers.swd & SR_Overflow))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BUSC:
					if(((registers.swd & SR_Sign) >> 3) != (registers.swd & SR_Carry))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case NOPP:
					break;
				case BNC:
					if(!(registers.swd & SR_Carry))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BNOV:
					if(!(registers.swd & SR_Overflow))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BMI:
					if(registers.swd & SR_Sign)
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BNEQ:
					if(!(registers.swd & SR_Zero))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BGE:
					if(((registers.swd & SR_Sign) >> 2) == (registers.swd & SR_Overflow))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BGT:
					if(!(registers.swd & SR_Zero) && ((registers.swd & SR_Sign) >> 2) == (registers.swd & SR_Overflow))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BESC:
					if(((registers.swd & SR_Sign) >> 3) == (registers.swd & SR_Carry))
					{
						registers.r[7] = cast(ushort)address;
						cycleCount += 2;
					}
					break;
				case BEXT:
					// handle this somehow???
					assert(false, "!");
				case MVO:
					memmap.Write16_BE_Aligned(address, registers.r[target]);
					break;
				case MVI:
					registers.r[target] = cast(ushort)operand;
					break;
				default:
				{
//					machine.DebugBreak("Illegal opcode", BR_IllegalOpcode);
					assert(false, "Unknown opcode!");
				}
			}

			static if(EnableDissassembly)
			{
				if(bDisOpValid)
					WriteToLog(&disOp);
			}

			// check for interrupts
			if(sOpcodeTable[instruction].interruptible)
			{
				if(bBUSRQ)
				{
					// handle bus request
					bBUSRQ = false;
					Halt(); // halt the cpu so other stuff can use the bus without the CPU interfering...
				}
				else if(bNMIPending || (irqLineState && (registers.swd & SR_InterruptEnable)))
				{
//					DebugJumpToSub(registers.r[7], 0x1004, bNMIPending ? 0 : 1);

					// acknowledge the interrupt
					bNMIPending = false;
					if(intAckHandler)
						intAckHandler(this);

					// handle interrupt
					memmap.Write16_BE_Aligned(registers.r[6]++, registers.r[7]);
					registers.r[7] = 0x1004; // jump to the interrupt vector...
					cycleCount += 7;
				}
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

		// guard against bad code...
		if(opcode == 0xFFFF)
			return 0;

		// decode the instruction
		Instruction instruction = cast(Instruction)DecodeInstruction(opcode);
		if(instruction >= Instruction.MAX)
			return 0;

		AddressModes am = GetAddressMode(instruction, opcode);

		pOpcode.instructionName = pOpcodeNames[instruction];
		pOpcode.lineTemplate = pAsmTemplate[am];

		uint target = 0;
		uint increment = 0;

		switch(am) with(AddressModes)
		{
			case Implied:
				// decode special J instruction
				if(instruction == Instruction.J)
				{
					target = memmap.Read16_BE_Aligned(address++);
					ushort loword = memmap.Read16_BE_Aligned(address);
					pOpcode.programCode[pOpcode.pcWords++] = target;
					pOpcode.programCode[pOpcode.pcWords++] = loword;
					int i = target & 0x3;
					int r = (target >> 8) & 0x3;
					target = ((target & 0xFC) << 8) | loword & 0x3FF;

					if(r != 3)
					{
						if(r == 1 && i == 0)
						{
							pOpcode.lineTemplate = pAsmTemplate[Direct];
							pOpcode.instructionName = "CALL";
						}
						else
						{
							pOpcode.lineTemplate = pAsmTemplate[RegisterDirect];
							pOpcode.instructionName ~= "SR";
							pOpcode.args[0].type = DisassembledOp.Arg.Type.Register;
							pOpcode.args[0].value = 4 + r;
							pOpcode.args[0].arg = regInfo[4 + r].name;
							++pOpcode.numArgs;
						}
					}
					else
					{
						pOpcode.lineTemplate = pAsmTemplate[Direct];
						pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
						pOpcode.flags |= DisassembledOp.Flags.Jump; // should all jumps get this flag? the others are effectively calls...
					}

					pOpcode.args[pOpcode.numArgs].type = DisassembledOp.Arg.Type.JumpTarget;
					pOpcode.args[pOpcode.numArgs].arg.format("$%04X", target);
					++pOpcode.numArgs;

					if(i == 1)
						pOpcode.instructionName ~= "E";
					else if(i == 2)
						pOpcode.instructionName ~= "D";
				}
				break;
			case RegisterImmediate:
				target = opcode & 3;
				pOpcode.args[0].type = DisassembledOp.Arg.Type.Register;
				pOpcode.args[0].value = cast(ubyte)target;
				pOpcode.args[0].arg = regInfo[target].name;
				pOpcode.args[1].type = DisassembledOp.Arg.Type.Constant;
				pOpcode.args[1].value = (opcode & 4) ? 2 : 1;
				pOpcode.args[1].arg.format("%d", pOpcode.args[1].value);
				pOpcode.numArgs = 2;
				break;
			case RegisterRegister:
				address = (opcode >> 3) & 7;
				pOpcode.args[pOpcode.numArgs].type = DisassembledOp.Arg.Type.Register;
				pOpcode.args[pOpcode.numArgs].value = cast(ubyte)address;
				pOpcode.args[pOpcode.numArgs].arg = regInfo[address].name;
				++pOpcode.numArgs;
				goto case;
			case Register:
				target = opcode & 7;
				switch(instruction) with(Instruction)
				{
					case MOVR:
						// alias for jump return
						if(target == 7 && address != 7)
						{
							pOpcode.lineTemplate = pAsmTemplate[Register];
							pOpcode.instructionName = "JR";
							pOpcode.flags |= DisassembledOp.Flags.Return;
							pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
							break;
						}
						goto case;
					case XORR:
						// some more special aliases
						if(target == address)
						{
							pOpcode.lineTemplate = pAsmTemplate[Register];
							pOpcode.instructionName = instruction == XORR ? "CLRR" : "TSTR";
							break;
						}
						goto default;
					default:
						pOpcode.args[pOpcode.numArgs].type = DisassembledOp.Arg.Type.Register;
						pOpcode.args[pOpcode.numArgs].value = cast(ubyte)target;
						pOpcode.args[pOpcode.numArgs].arg = regInfo[target].name;
						++pOpcode.numArgs;
				}
				break;
			case Direct:
				target = memmap.Read16_BE_Aligned(address++);
				pOpcode.programCode[pOpcode.pcWords++] = target;
				address = (opcode & 0x20) ? address - target - 1 : address + target;
				pOpcode.args[0].type = DisassembledOp.Arg.Type.JumpTarget;
				pOpcode.args[0].value = address;
				pOpcode.args[0].arg.format("$%04X", address);
				pOpcode.numArgs = 1;
				break;
			case DirectRegister:
			case Indirect:
			case Immediate:
				target = (opcode >> 3) & 7;

				// update the instruction names
				if(am == Indirect)
					pOpcode.instructionName ~= "@";
				else if(am == Immediate)
					pOpcode.instructionName ~= "I";

				// if the source is the stack pointer, handle the pre-decrement...
				if(target == 6)
				{
					if(instruction == Instruction.MVO)
						increment = 1;
				}
				else if(target == 4 || target == 5 || target == 7)
				{
					// auto-increment registers
					increment = 1;
				}

				if(target == 0)
				{
					address = memmap.Read16_BE_Aligned(address);
					pOpcode.programCode[pOpcode.pcWords++] = address;
					pOpcode.args[0].type = DisassembledOp.Arg.Type.Address;
					pOpcode.args[0].value = address;
					pOpcode.args[0].arg.format("$%04X", address);
				}
				else if(target == 7)
				{
					ushort imm = 0;

					// look up the value
					if(dissOp_swd & SR_DoubleByteData)
					{
						ushort l = memmap.Read16_BE_Aligned(address);
						ushort h = memmap.Read16_BE_Aligned(address+increment);
						pOpcode.programCode[pOpcode.pcWords++] = l;
						pOpcode.programCode[pOpcode.pcWords++] = h;
						imm = (l & 0xFF) | ((h & 0xFF) << 8);
					}
					else
					{
						imm = memmap.Read16_BE_Aligned(address);
						pOpcode.programCode[pOpcode.pcWords++] = imm;
					}

					pOpcode.args[0].type = DisassembledOp.Arg.Type.Immediate;
					pOpcode.args[0].value = cast(uint)imm;
					pOpcode.args[0].arg.format("#$%X", cast(int)imm);
				}
				else if(target == 6 && (instruction == Instruction.MVI || instruction == Instruction.MVO))
				{
					address = opcode & 7;
					if(instruction == Instruction.MVI && address == 7)
					{
						pOpcode.lineTemplate = pAsmTemplate[Implied];
						pOpcode.instructionName = "RETURN";
						pOpcode.flags |= DisassembledOp.Flags.Return;
						pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
					}
/*
					// this alias is fairly standard in code, but it tends to appear in crazy places in the disassembly.
					else if(instruction == Instruction.MVO && address == 5)
					{
						pOpcode.lineTemplate = pAsmTemplate[Implied];
						pOpcode.instructionName = "BEGIN";
					}
*/
					else
					{
						pOpcode.lineTemplate = pAsmTemplate[Register];
						pOpcode.instructionName = instruction == Instruction.MVI ? "PULR" : "PSHR";
						pOpcode.args[0].type = DisassembledOp.Arg.Type.Register;
						pOpcode.args[0].value = cast(ubyte)address;
						pOpcode.args[0].arg = regInfo[address].name;
						pOpcode.numArgs = 1;
					}
					break;
				}
				else
				{
					pOpcode.args[0].type = DisassembledOp.Arg.Type.Register;
					pOpcode.args[0].value = cast(ubyte)target;
					pOpcode.args[0].arg = regInfo[target].name;
				}

				address = opcode & 7;
				pOpcode.args[1].type = DisassembledOp.Arg.Type.Register;
				pOpcode.args[1].value = cast(ubyte)address;
				pOpcode.args[1].arg = regInfo[address].name;
				pOpcode.numArgs = 2;
				break;
			default:
				break;
		}

		dissOp_swd &= ~SR_DoubleByteData;

		if(instruction == Instruction.HLT)
			pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
		else if(instruction >= Instruction.B && instruction <= Instruction.BEXT)
			pOpcode.flags |= DisassembledOp.Flags.Branch;
		else if(instruction == Instruction.MVI)
		{
			pOpcode.flags |= DisassembledOp.Flags.Load;

			if(am == AddressModes.DirectRegister)
				pOpcode.args[0].type = DisassembledOp.Arg.Type.ReadAddress;
		}
		else if(instruction == Instruction.MVO)
		{
			pOpcode.flags |= DisassembledOp.Flags.Store;

			if(target != 6)
			{
				if(am == AddressModes.DirectRegister)
				{
					pOpcode.lineTemplate = pAsmTemplate[AddressModes.RegisterDirect];
					pOpcode.args[0].type = DisassembledOp.Arg.Type.WriteAddress;
				}
				else if(am == AddressModes.Immediate)
					assert(false, "Eek!");

				DisassembledOp.Arg t = pOpcode.args[0];
				pOpcode.args[0] = pOpcode.args[1];
				pOpcode.args[1] = t;
			}
		}
		else if(instruction == Instruction.SDBD)
		{
			dissOp_swd |= SR_DoubleByteData;
		}

		return pOpcode.pcWords;
	}

private:
	struct Registers
	{
		ushort r[8]; // 8 general purpose registers
		ushort swd;  // status word
	}

	Registers registers;
	bool bBUSRQ;
	bool bDebugFlag;

	ushort dissOp_swd; // used by the disassembler

	void FLAGSZ(int result) nothrow		{ registers.swd = (registers.swd & ~(SR_Sign | SR_Zero)) | ((result & 0x8000) ? SR_Sign : 0) | (!(result & 0xFFFF) ? SR_Zero : 0); }
	void FLAGSbZ(int result) nothrow	{ registers.swd = (registers.swd & ~(SR_Sign | SR_Zero)) | ((result & 0x80) ? SR_Sign : 0) | (!(result & 0xFFFF) ? SR_Zero : 0); }
	void FLAGSZC(int result) nothrow	{ registers.swd = (registers.swd & ~(SR_Sign | SR_Zero | SR_Carry | SR_Overflow)) | ((result & 0x8000) ? SR_Sign : 0) | (!(result & 0xFFFF) ? SR_Zero : 0) | ((result & 0x10000) ? SR_Carry : 0); }

	/+inline+/ int DecodeInstruction(ushort opcode)
	{
		ushort instruction = (opcode & 0x3ff);

		ushort result = Instruction.UNKNOWN;

		if((instruction >> 3) == 0)
		{
			//HLT - SETC
			result = instruction;
		}
		else if((instruction < 0x80))
		{
			//INCR - SARC
			result = cast(ushort)((instruction >> 3) + (instruction < 0x38 ? 7 : 9));

			if(result == Instruction.GSWD)
			{
				if(instruction & 0x04 && instruction & 0x02)
					result += 2; //SIN
				else if(instruction & 0x04)
					result += 1; //NOP
			}
		}
		else if(instruction < 0x200)
		{
			// MOVR - XORR
			result = ((instruction >> 6) + 23); //+24 == MOVR - 1
		}
		else if(instruction < 0x240)
		{
			//B - BEXT
			result = ((instruction & 0x1f) + 0x1f); //+0x1f == B
		}
		else
		{
			// MVO - XOR
			result = ((instruction >> 6) + 39); //+39 == MVO - 9
		}

		return result;
	}

	/+inline+/ AddressModes GetAddressMode(int instruction, ushort opcode)
	{
		AddressModes am = cast(AddressModes)sOpcodeTable[instruction].am;

		if(am == AddressModes.Select)
		{
			opcode &= 0x38;
			if(opcode == 0)
				return AddressModes.DirectRegister;
			else if(opcode == 0x38)
				return AddressModes.Immediate;
			else
				return AddressModes.Indirect;
		}

		return am;
	}
}

enum Instruction
{
    // tiny ops
    HLT   = 0x00,	// Halt
    SDBD  = 0x01,	// Set Double Byte Data
    EIS   = 0x02,	// Enable Interrupt System
    DIS   = 0x03,	// Disable Interrupt System
    J     = 0x04,	// Jump
    TCI   = 0x05,	// Terminate Current Interrupt
    CLRC  = 0x06,	// Clear Carry
    SETC  = 0x07,	// Set Carry

    // small ops
    INCR  = 0x08,	// Increment Register
    DECR  = 0x09,	// Decrement Register
    COMR  = 0x0a,	// Complement Register
    NEGR  = 0x0b,	// Negate Register
    ADCR  = 0x0c,	// Add Carry to Register
    GSWD  = 0x0d,	// Get the Status Word
    NOP   = 0x0e, // No Operation //JSGH
    SIN   = 0x0f, // Software Interrupt //JSGH
    RSWD  = 0x10,	// Return Status Word
    SWAP  = 0x11,	// Swap Bytes
    SLL   = 0x12,	// Shift Logical Left
    RLC   = 0x13,	// Rotate Left through Carry
    SLLC  = 0x14,	// Shift Logical Left through Carry
    SLR   = 0x15,	// Shift Logical Right
    SAR   = 0x16,	// Shift Arithmetic Right
    RRC   = 0x17,	// Rotate Right through Carry
    SARC  = 0x18,	// Shift Arithmetic Right through Carry

    // big ops
    MOVR  = 0x19,	// Move Register
    ADDR  = 0x1a,	// Add Registers
    SUBR  = 0x1b,	// Subtract Registers
    CMPR  = 0x1c,	// Compare Registers
    ANDR  = 0x1d,	// And Registers
    XORR  = 0x1e,	// Xor Registers

    // branch ops
    B     = 0x1f,		// Branch Unconditional
    BC    = 0x20,		// Branch on Carry
    BOV   = 0x21,	// Branch on Overflow
    BPL   = 0x22,	// Branch on Plus
    BEQ   = 0x23,	// Branch of Equal
    BLT   = 0x24,	// Branch of Less Than
    BLE   = 0x25,	// Branch if Less Than or Equal
    BUSC  = 0x26,	// Branch on Unequal Sign and Carry
    NOPP  = 0x27,	// No Operation
    BNC   = 0x28,	// Branch on Carry Clear
    BNOV  = 0x29,	// Branch on Overflow Clear
    BMI   = 0x2a,	// Branch on Minus
    BNEQ  = 0x2b,	// Branch of Not Equal
    BGE   = 0x2c,	// Branch if Greater or Equal
    BGT   = 0x2d,	// Branch if Greater Than
    BESC  = 0x2e,	// Branch on Equal Sign and Carry
    BEXT  = 0x2f,	// Branch on External

    MVO   = 0x30,	// Move Out
    MVI   = 0x31,	// Move In
    ADD   = 0x32,	// Add
    SUB   = 0x33,	// Subtract
    CMP   = 0x34,	// Compare
    AND   = 0x35,	// And
    XOR   = 0x36,	// Xor

    MAX,
    UNKNOWN = 255,	// Unknown opcode
}

enum AddressModes
{
    Implied,
    Register,
    RegisterImmediate,
    RegisterRegister,
    Direct,
    DirectRegister,
    RegisterDirect,
    Immediate,
    Indirect,
    Branch,

    Select,

    Max
}

enum : ushort
{
    SR_Sign = 0x8080,
    SR_Zero = 0x4040,
    SR_Overflow = 0x2020,
    SR_Carry = 0x1010,
    SR_InterruptEnable = 0x1,
    SR_DoubleByteData = 0x2,
}

struct Opcode
{
    ubyte op;
    ubyte am;
    ubyte cc;
    ubyte interruptible;
}

const Opcode sOpcodeTable[] =
[
	Opcode( Instruction.HLT,  AddressModes.Implied, 0, 0 ),
	Opcode( Instruction.SDBD, AddressModes.Implied, 4, 0 ),
	Opcode( Instruction.EIS,  AddressModes.Implied, 4, 0 ),
	Opcode( Instruction.DIS,  AddressModes.Implied, 4, 0 ),
	Opcode( Instruction.J,    AddressModes.Implied, 12, 1 ),
	Opcode( Instruction.TCI,  AddressModes.Implied, 4, 0 ),
	Opcode( Instruction.CLRC, AddressModes.Implied, 4, 0 ),
	Opcode( Instruction.SETC, AddressModes.Implied, 4, 0 ),
	Opcode( Instruction.INCR, AddressModes.Register, 6, 1 ),
	Opcode( Instruction.DECR, AddressModes.Register, 6, 1 ),
	Opcode( Instruction.COMR, AddressModes.Register, 6, 1 ),
	Opcode( Instruction.NEGR, AddressModes.Register, 6, 1 ),
	Opcode( Instruction.ADCR, AddressModes.Register, 6, 1 ),
	Opcode( Instruction.GSWD, AddressModes.Register, 6, 1 ),

	Opcode( Instruction.NOP,  AddressModes.Implied, 6, 1 ),
	Opcode( Instruction.SIN,  AddressModes.Implied, 6, 1 ),

	Opcode( Instruction.RSWD, AddressModes.Register, 6, 1 ),
	Opcode( Instruction.SWAP, AddressModes.RegisterImmediate, 6, 0 ),
	Opcode( Instruction.SLL,  AddressModes.RegisterImmediate, 6, 0 ),
	Opcode( Instruction.RLC,  AddressModes.RegisterImmediate, 6, 0 ),
	Opcode( Instruction.SLLC, AddressModes.RegisterImmediate, 6, 0 ),
	Opcode( Instruction.SLR,  AddressModes.RegisterImmediate, 6, 0 ),
	Opcode( Instruction.SAR,  AddressModes.RegisterImmediate, 6, 0 ),
	Opcode( Instruction.RRC,  AddressModes.RegisterImmediate, 6, 0 ),
	Opcode( Instruction.SARC, AddressModes.RegisterImmediate, 6, 0 ),
	Opcode( Instruction.MOVR, AddressModes.RegisterRegister, 6, 1 ),
	Opcode( Instruction.ADDR, AddressModes.RegisterRegister, 6, 1 ),
	Opcode( Instruction.SUBR, AddressModes.RegisterRegister, 6, 1 ),
	Opcode( Instruction.CMPR, AddressModes.RegisterRegister, 6, 1 ),
	Opcode( Instruction.ANDR, AddressModes.RegisterRegister, 6, 1 ),
	Opcode( Instruction.XORR, AddressModes.RegisterRegister, 6, 1 ),

	Opcode( Instruction.B,    AddressModes.Direct, 9, 1 ),
	Opcode( Instruction.BC,   AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BOV,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BPL,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BEQ,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BLT,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BLE,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BUSC, AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.NOPP, AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BNC,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BNOV, AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BMI,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BNEQ, AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BGE,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BGT,  AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BESC, AddressModes.Direct, 7, 1 ),
	Opcode( Instruction.BEXT, AddressModes.Direct, 7, 1 ),

	Opcode( Instruction.MVO,  AddressModes.Select, 9, 0 ),
	Opcode( Instruction.MVI,  AddressModes.Select, 8, 1 ),
	Opcode( Instruction.ADD,  AddressModes.Select, 8, 1 ),
	Opcode( Instruction.SUB,  AddressModes.Select, 8, 1 ),
	Opcode( Instruction.CMP,  AddressModes.Select, 8, 1 ),
	Opcode( Instruction.AND,  AddressModes.Select, 8, 1 ),
	Opcode( Instruction.XOR,  AddressModes.Select, 8, 1 )
];

immutable string[] pAsmTemplate =
[
	"%s",
	"%s %s",
	"%s %s, %s",
	"%s %s, %s",
	"%s %s",
	"%s %s, %s",
	"%s %s, %s",
	"%s %s, %s",
	"%s %s, %s"
];

immutable string[Instruction.MAX] pOpcodeNames =
[
	"HLT",
	"SDBD",
	"EIS",
	"DIS",
	"J",
	"TCI",
	"CLRC",
	"SETC",
	"INCR",
	"DECR",
	"COMR",
	"NEGR",
	"ADCR",
	"GSWD",
	"NOP",
	"SIN",
	"RSWD",
	"SWAP",
	"SLL",
	"RLC",
	"SLLC",
	"SLR",
	"SAR",
	"RRC",
	"SARC",
	"MOVR",
	"ADDR",
	"SUBR",
	"CMPR",
	"ANDR",
	"XORR",
	"B",
	"BC",
	"BOV",
	"BPL",
	"BEQ",
	"BLT",
	"BLE",
	"BUSC",
	"NOPP",
	"BNC",
	"BNOV",
	"BMI",
	"BNEQ",
	"BGE",
	"BGT",
	"BESC",
	"BEXT",
	"MVO",
	"MVI",
	"ADD",
	"SUB",
	"CMP",
	"AND",
	"XOR"
];

static RegisterInfo[] sRegInfo =
[
	RegisterInfo( "R0", 16, 0, null ),
	RegisterInfo( "R1", 16, 0, null ),
	RegisterInfo( "R2", 16, 0, null ),
	RegisterInfo( "R3", 16, 0, null ),
	RegisterInfo( "R4", 16, 0, null ),
	RegisterInfo( "R5", 16, 0, null ),
	//RegisterInfo( "R6", 16, RegisterInfo.Flags.StackPointer, null ),
	RegisterInfo( "SP", 16, RegisterInfo.Flags.StackPointer, null ),
	//RegisterInfo( "R7", 16, RegisterInfo.Flags.ProgramCounter, null ),
	RegisterInfo( "PC", 16, RegisterInfo.Flags.ProgramCounter, null ),
	RegisterInfo( "SWD", 16, RegisterInfo.Flags.FlagsRegister, "SZOC????SZOC????" )
];

static string[] sProcessorName =
[
	"CP1600",
	"CP1610"
];

module demu.parts.cpu.mos6502;

import demu.machine;
import demu.memmap;
import demu.parts.part;
import demu.parts.processor;

import std.string;

class Z80 : Processor
{
	enum Version
	{
		MOS6502,
		MOS6507,
		MOS6510,
	}

	this(Machine machine, string name, MemMap memmap, Version processorRevision)
	{
		super(machine, name, Part.Feature.Stack | Part.Feature.Code | Part.Feature.Registers);
		MemoryMap = memmap;

		this.processorRevision = processorRevision;

		procInfo.name = sProcessorName[processorRevision];
		procInfo.processorFamily = "6502";
		procInfo.endian = Endian.Little;
		procInfo.addressWidth = processorRevision == Version.MOS6507 ? 13 : 16;
		procInfo.addressMask = processorRevision == Version.MOS6507 ? 0x1FFF : 0xFFFF;
		procInfo.stackOffset = 0x100;
		procInfo.opcodeWidth = 8;
		procInfo.maxOpwords = 3;
		procInfo.maxAsmLineLength = 12;

		regInfo = sRegInfo;
		displayRegs = sDisplayRegs;

		registers.pc = 0;
		registers.ac = 0;
		registers.x = 0;
		registers.y = 0;
		registers.sr = SR_Unused;
		registers.sp = 0xFF;

//		pCurrentOp = NULL;
//		bSync = false;

		stage = 0;
	}

	uint Reset()
	{
		registers = Registers.init;

		if(processorRevision == Version.MOS6510)
		{
			memmap.Write8(MappedRegisters.ProcessorPortDataDirection, ProcessorPortFlags.DefaultDataDirectionValue);
			memmap.Write8(MappedRegisters.ProcessorPort,              ProcessorPortFlags.DefaultPortValue);
		}

		registers.sr |= SR_Unused;
		registers.sp = 0xff;

		startAddress = Read16_LE(0xFFFC);  // read the reset address from the reset vector
		registers.pc = cast(ushort)startAddress;

		if(processorRevision == Version.MOS6507) // for some reason the 6507 always seems to have the break bit set... :/
			registers.sr |= SR_Break;

//		pCurrentOp = NULL;

		stage = 0;

		return super.Reset();
	}

	void SetProgramCounter(uint pc) nothrow
	{
		registers.pc = cast(ushort)pc;
	}

	int Execute(int numCycles, uint breakConditions)
	{
		bYield = false;

		int remainingCycles = numCycles;
		while(remainingCycles > 0 && !bYield)
		{
			static if(EnableDissassembly)
			{
				DisassembledOp disOp = void;
				bool bDisOpValid = false;
				ushort pc = registers.pc;
			}

			ulong cc = cycleCount;
			waitCycles = 0;

			// we want to skip this part if we are executing a multi-stage op
			if(stage == 0)
			{
				// handle any pending interrupts
				if(bNMIPending)
				{
					// Set the interrupt flag first so Read8() can know it's coming from an IRQ
					// Copy sr first so we don't push the wrong value on the stack
					ubyte sr = registers.sr;
					registers.sr |= SR_Interrupt;
					ushort target = Read16_LE(0xfffa);

					// allow the debugger to track the callstack
//					DebugJumpToSub(registers.pc, target, 0);

					Write8(0x100 + registers.sp--, registers.pc >> 8);
					Write8(0x100 + registers.sp--, registers.pc & 0xFF);
					Write8(0x100 + registers.sp--, sr);
					registers.pc = target;

					bNMIPending = false;

					cycleCount += 7;
					cc = cycleCount;
				}
				if(irqLineState)
				{
					if(!(registers.sr & SR_Interrupt))
					{
						// acknowledge the interrupt
						if(intAckHandler)
							intAckHandler(this);

						// Set the interrupt flag first so Read8() can know it's coming from an IRQ
						// Copy sr first so we don't push the wrong value on the stack
						ubyte sr = registers.sr;
						registers.sr |= SR_Interrupt;
						ushort target = Read16_LE(0xfffe);

						// allow the debugger to track the callstack
//						DebugJumpToSub(registers.pc, target, 1);

						Write8(0x100 + registers.sp--, registers.pc >> 8);
						Write8(0x100 + registers.sp--, registers.pc & 0xFF);
						Write8(0x100 + registers.sp--, sr);
						registers.pc = target;

						cycleCount += 7;
						cc = cycleCount;
					}
				}

				// allow the debugger to step the cpu
//				if(DebugBeginStep(registers.pc))
//					break;

				static if(EnableDissassembly)
				{
					// log the instruction stream
					if(bLogExecution)
						bDisOpValid = !!DisassembleOp(registers.pc, &disOp);
					pc = registers.pc;
				}

				// read the next op at the program counter
//				bSync = true;
//				TRACK_OPCODE(registers.pc);
				ubyte opcode = Read8(registers.pc++);
//				bSync = false;

				// lookup the opcode data from the opcode table
				op = opcodeTable[opcode].op;
				addressMode = opcodeTable[opcode].addressingMode;
//				pCurrentOp = &opcodeTable[opcode];

				// increment the cpu cycle count
				cycleCount += opcodeTable[opcode].cycleCount;

				// calculate the operand based on the addressing mode
				switch(addressMode)
				{
					case AddressingMode.Accumulator:
						// operand is the accumulator
						operand = registers.ac;
						break;

					case AddressingMode.Immediate:
						// operand is an immediate byte
						operand = Read8(registers.pc++);
						break;

					case AddressingMode.ZeroPage:
						// operand is a value from the zero page
						address = Read8(registers.pc++);
						if(op >= Instruction.ADC)
							operand = Read8(address);
						break;

					case AddressingMode.ZeroPageX:
						// operand is a value from the zero page with an offset in X
						address = (Read8(registers.pc++) + registers.x) & 0xFF;
						if(op >= Instruction.ADC)
							operand = Read8(address);
						break;

					case AddressingMode.ZeroPageY:
						// operand is a value from the zero page with an offset in Y
						address = (Read8(registers.pc++) + registers.y) & 0xFF;
						if(op >= Instruction.ADC)
							operand = Read8(address);
						break;

					case AddressingMode.Absolute:
						// operand is an absolute address
						address = Read16_LE(registers.pc);
						registers.pc += 2;
						if(op >= Instruction.ADC)
							operand = Read8(address);
						break;

					case AddressingMode.AbsoluteX:
						// operand is an absolute address with an offset in X
						address = Read8(registers.pc++);
						if(address + registers.x >= 0x100)
							++cycleCount; // cross page addressing requires an additional CPU cycle
						address |= Read8(registers.pc++) << 8;
						address += registers.x;
						if(op >= Instruction.ADC)
							operand = Read8(address);
						break;

					case AddressingMode.AbsoluteY:
						// operand is an absolute address with an offset in Y
						address = Read8(registers.pc++);
						if(address + registers.y >= 0x100)
							++cycleCount; // cross page addressing requires an additional CPU cycle
						address |= Read8(registers.pc++) << 8;
						address += registers.y;
						if(op >= Instruction.ADC)
							operand = Read8(address);
						break;

					case AddressingMode.Indirect:
					{
						// operand is an indirect address
						int target = Read16_LE(registers.pc);
						registers.pc += 2;
						address = Read8(target);
						target = (target & 0xFF00) | ((target + 1) & 0xFF); // indirect jump can not cross page boundaries
						address |= Read8(target) << 8;
						break;
					}

					case AddressingMode.XIndirect:
					{
						// operand is an indirect address from an offset in X
						int target = (Read8(registers.pc++) + registers.x) & 0xFF;
						address = Read16_LE(target);
						if(op >= Instruction.ADC)
							operand = Read8(address);
						break;
					}

					case AddressingMode.IndirectY:
					{
						// operand is an indirect address with an offset in Y
						int target = Read8(registers.pc++);
						address = Read8(target++);
						if(address + registers.y >= 0x100)
							++cycleCount; // cross page addressing requires an additional CPU cycle
						address |= Read8(target) << 8;
						address += registers.y;
						if(op >= Instruction.ADC)
							operand = Read8(address);
						break;
					}

					case AddressingMode.Relative:
						// operand is an relative address
						address = registers.pc + cast(byte)Read8(registers.pc++);
						break;
					default:
						break;
				}
			}

			// perform the operation
			switch(op)
			{
				case Instruction.ADC:
				{
					int result;
					if(registers.sr & SR_Decimal)
					{
						int ln = (registers.ac & 0xF) + (operand & 0xF) + (registers.sr & SR_Carry);
						if(ln > 9) ln += 6;
						result = (registers.ac & 0xF0) + (operand & 0xF0) + ln;
						if((result & 0x1F0) > 0x90)
							result += 0x60;
					}
					else
						result = registers.ac + operand + (registers.sr & SR_Carry);
					FLAGNZCV(result, operand);
					registers.ac = cast(ubyte)result;
					break;
				}

				case Instruction.AND:
					registers.ac &= operand;
					FLAGNZ(registers.ac);
					break;

				case Instruction.ASL:
					operand <<= 1;
					if(addressMode == AddressingMode.Accumulator)
						registers.ac = cast(ubyte)operand;
					else
						Write8(address, cast(ubyte)operand);
					FLAGNZC(operand);
					break;

				case Instruction.BCC:
					if(!(registers.sr & SR_Carry))
					{
						if(address >> 8 != registers.pc >> 8)
							++cycleCount;
						registers.pc = cast(ushort)address;
						++cycleCount;
					}
					break;

				case Instruction.BCS:
					if(registers.sr & SR_Carry)
					{
						if(address >> 8 != registers.pc >> 8)
							++cycleCount;
						registers.pc = cast(ushort)address;
						++cycleCount;
					}
					break;

				case Instruction.BEQ:
					if(registers.sr & SR_Zero)
					{
						if(address >> 8 != registers.pc >> 8)
							++cycleCount;
						registers.pc = cast(ushort)address;
						++cycleCount;
					}
					break;

				case Instruction.BIT:
					registers.sr &= ~(SR_Zero|SR_Negative|SR_Overflow);
					registers.sr |= operand & (SR_Negative|SR_Overflow);
					registers.sr |= (operand & registers.ac) ? 0 : SR_Zero;
					break;

				case Instruction.BMI:
					if(registers.sr & SR_Negative)
					{
						if(address >> 8 != registers.pc >> 8)
							++cycleCount;
						registers.pc = cast(ushort)address;
						++cycleCount;
					}
					break;

				case Instruction.BNE:
					if(!(registers.sr & SR_Zero))
					{
						if(address >> 8 != registers.pc >> 8)
							++cycleCount;
						registers.pc = cast(ushort)address;
						++cycleCount;
					}
					break;

				case Instruction.BPL:
					if(!(registers.sr & SR_Negative))
					{
						if(address >> 8 != registers.pc >> 8)
							++cycleCount;
						registers.pc = cast(ushort)address;
						++cycleCount;
					}
					break;

				case Instruction.BRK:
				{
					ubyte sr = registers.sr | SR_Break; // the B flag is pushed to the stack
					registers.sr |= SR_Interrupt;       // the I flag is set
					registers.pc++;                     // BRK stores PC+2 on the stack

					ushort target = Read16_LE(0xfffe);

					// allow the debugger to track the callstack
//					DebugJumpToSub(registers.pc, target, 1);

					Write8(0x100 + registers.sp--, registers.pc >> 8);
					Write8(0x100 + registers.sp--, registers.pc & 0xFF);
					Write8(0x100 + registers.sp--, sr);
					registers.pc = target;

					// allow the debugger to break
//					machine.DebugBreak("BRK instruction reached", BR_HaltInstruction);
					break;
				}

				case Instruction.BVC:
					if(!(registers.sr & SR_Overflow))
					{
						if(address >> 8 != registers.pc >> 8)
							++cycleCount;
						registers.pc = cast(ushort)address;
						++cycleCount;
					}
					break;

				case Instruction.BVS:
					if(registers.sr & SR_Overflow)
					{
						if(address >> 8 != registers.pc >> 8)
							++cycleCount;
						registers.pc = cast(ushort)address;
						++cycleCount;
					}
					break;

				case Instruction.CLC:
					registers.sr &= ~SR_Carry;
					break;

				case Instruction.CLD:
					registers.sr &= ~SR_Decimal;
					break;

				case Instruction.CLI:
					registers.sr &= ~SR_Interrupt;
					break;

				case Instruction.CLV:
					registers.sr &= ~SR_Overflow;
					break;

				case Instruction.CMP:
					operand = registers.ac + 0x100 - operand;
					FLAGNZC(operand);
					break;

				case Instruction.CPX:
					operand = registers.x + 0x100 - operand;
					FLAGNZC(operand);
					break;

				case Instruction.CPY:
					operand = registers.y + 0x100 - operand;
					FLAGNZC(operand);
					break;

				case Instruction.DEC:
					Write8(address, cast(ubyte)--operand);
					FLAGNZ(operand);
					break;

				case Instruction.DEX:
					--registers.x;
					FLAGNZ(registers.x);
					break;

				case Instruction.DEY:
					--registers.y;
					FLAGNZ(registers.y);
					break;

				case Instruction.EOR:
					registers.ac ^= operand;
					FLAGNZ(registers.ac);
					break;

				case Instruction.INC:
					Write8(address, cast(ubyte)++operand);
					FLAGNZ(operand);
					break;

				case Instruction.INX:
					++registers.x;
					FLAGNZ(registers.x);
					break;

				case Instruction.INY:
					++registers.y;
					FLAGNZ(registers.y);
					break;

				case Instruction.JMP:
					registers.pc = cast(ushort)address;
					break;

				case Instruction.JSR:
					// allow the debugger to track the callstack
//					DebugJumpToSub(registers.pc, address, -1);

					--registers.pc;
					Write8(0x100 + registers.sp--, registers.pc >> 8);
					Write8(0x100 + registers.sp--, registers.pc & 0xFF);
					registers.pc = cast(ushort)address;
					break;

				case Instruction.LDA:
					registers.ac = cast(ubyte)operand;
					FLAGNZ(operand);
					break;

				case Instruction.LDX:
					registers.x = cast(ubyte)operand;
					FLAGNZ(operand);
					break;

				case Instruction.LDY:
					registers.y = cast(ubyte)operand;
					FLAGNZ(operand);
					break;

				case Instruction.LSR:
					operand = (operand >> 1) | ((operand & SR_Carry) << 8);
					if(addressMode == AddressingMode.Accumulator)
						registers.ac = cast(ubyte)operand;
					else
						Write8(address, cast(ubyte)operand);
					FLAGNZC(operand);
					break;

				case Instruction.NOP:
					break;

				case Instruction.ORA:
					registers.ac |= operand;
					FLAGNZ(registers.ac);
					break;

				case Instruction.PHA:
					Write8(0x100 + registers.sp--, registers.ac);
					break;

				case Instruction.PHP:
					Write8(0x100 + registers.sp--, registers.sr);
					break;

				case Instruction.PLA:
					registers.ac = Read8(++registers.sp + 0x100);
					FLAGNZ(registers.ac);
					break;

				case Instruction.PLP:
					registers.sr = Read8(++registers.sp + 0x100) | SR_Unused;
					break;

				case Instruction.ROL:
					operand = (operand << 1) | (registers.sr & SR_Carry);
					if(addressMode == AddressingMode.Accumulator)
						registers.ac = cast(ubyte)operand;
					else
						Write8(address, cast(ubyte)operand);
					FLAGNZC(operand);
					break;

				case Instruction.ROR:
					operand = (operand >> 1) | ((operand & SR_Carry) << 8) | ((registers.sr & SR_Carry) << 7);
					if(addressMode == AddressingMode.Accumulator)
						registers.ac = cast(ubyte)operand;
					else
						Write8(address, cast(ubyte)operand);
					FLAGNZC(operand);
					break;

				case Instruction.RTI:
					registers.sr = Read8(++registers.sp + 0x100);       // read the status register
					registers.pc = Read8(++registers.sp + 0x100);
					registers.pc |= Read8(++registers.sp + 0x100) << 8; // read the PC
					address = registers.pc;

					// allow the debugger to track of the callstack
//					DebugReturnFromSub(registers.pc);
					break;

				case Instruction.RTS:
					registers.pc = Read8(++registers.sp + 0x100);
					registers.pc |= Read8(++registers.sp + 0x100) << 8;
					++registers.pc;
					address = registers.pc;

					// allow the debugger to track of the callstack
//					DebugReturnFromSub(registers.pc);
					break;

				case Instruction.SBC:
					{
						int result;
						if(registers.sr & SR_Decimal)
						{
							int ln = (registers.ac & 0xF) - (operand & 0xF) - (~registers.sr & SR_Carry);
							if(ln & 0x10) ln -= 6;
							int hn = (registers.ac >> 4) - (operand >> 4) - ((ln & 0x10) >> 4);
							if(hn & 0x10) hn -= 6;
							result = (ln & 0xF) | (hn << 4);
						}
						else
							result = registers.ac - operand - (~registers.sr & SR_Carry);
						FLAGNZnCV(result, operand);
						registers.ac = cast(ubyte)result;
						break;
					}

				case Instruction.SEC:
					registers.sr |= SR_Carry;
					break;

				case Instruction.SED:
					registers.sr |= SR_Decimal;
					break;

				case Instruction.SEI:
					registers.sr |= SR_Interrupt;
					break;

				case Instruction.STA:
				case Instruction.STX:
				case Instruction.STY:
					// emulate the correct timing of the store operations by emulating a multi-state operation
					if(stage ==0)
					{
						++stage;
						--cycleCount;
					}
					else
					{
						cycleCount+=1; // should the cycle counter be updated before or after the store?
						Write8(address, (&registers.ac)[op - Instruction.STA]);
						stage = 0;
					}
					break;

				case Instruction.TAX:
					registers.x = registers.ac;
					FLAGNZ(registers.ac);
					break;

				case Instruction.TAY:
					registers.y = registers.ac;
					FLAGNZ(registers.ac);
					break;

				case Instruction.TSX:
					registers.x = registers.sp;
					FLAGNZ(registers.sp);
					break;

				case Instruction.TXA:
					registers.ac = registers.x;
					FLAGNZ(registers.x);
					break;

				case Instruction.TXS:
					registers.sp = registers.x;
					FLAGNZ(registers.x);
					break;

				case Instruction.TYA:
					registers.ac = registers.y;
					FLAGNZ(registers.y);
					break;

				default:
				{
					// invalid opcode!
//					machine.DebugBreak("Illegal opcode", BR_IllegalOpcode);
//					assert(false, "Unknown opcode!");
					break;
				}
			}

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

	uint GetRegisterValue(int reg)
	{
		switch(reg)
		{
			case Regs.PC: return registers.pc;
			case Regs.SP: return registers.sp;
			case Regs.AC: return registers.ac;
			case Regs.X:  return registers.x;
			case Regs.Y:  return registers.y;
			case Regs.SR: return registers.sr;
			default: break;
		}
		return -1;
	}

	void SetRegisterValue(int reg, uint value)
	{
		switch(reg)
		{
			case Regs.PC: registers.pc = cast(ushort)value; break;
			case Regs.SP: registers.sp = cast(ubyte)value;  break;
			case Regs.AC: registers.ac = cast(ubyte)value;  break;
			case Regs.X:  registers.x  = cast(ubyte)value;  break;
			case Regs.Y:  registers.y  = cast(ubyte)value;  break;
			case Regs.SR: registers.sr = cast(ubyte)value;  break;
			default: break;
		}
	}

	int DisassembleOp(uint address, DisassembledOp* pOpcode)
	{
		*pOpcode = DisassembledOp.init;
		pOpcode.programOffset = address & procInfo.addressMask;

		// read the next op at the program counter
//		bSync = true;
		ubyte opcode = Read8(address++);
//		bSync = false;

		pOpcode.programCode[pOpcode.pcWords++] = opcode;

		// lookup the opcode data from the opcode table
		Instruction op = cast(Instruction)opcodeTable[opcode].op;
		AddressingMode addressMode = cast(AddressingMode)opcodeTable[opcode].addressingMode;

		if(op == Instruction.UNK)
			return 0;

		pOpcode.instructionName = pOpcodeNames[op];
		pOpcode.lineTemplate = pASMTemplate[addressMode];

		switch(addressMode)
		{
			case AddressingMode.Implicit:
				// no args
				break;

			case AddressingMode.Accumulator:
				// NOTE: i don't think 6502 listing actually lists the 'A' operand... (comment this out?)
				pOpcode.numArgs = 1;
				pOpcode.args[0].arg = "A";
				pOpcode.args[0].value = 2;
				pOpcode.args[0].type = DisassembledOp.Arg.Type.Register;
				break;

			case AddressingMode.ZeroPageX:
			case AddressingMode.ZeroPageY:
			case AddressingMode.XIndirect:
			case AddressingMode.IndirectY:
			case AddressingMode.Immediate:
			case AddressingMode.ZeroPage:
			case AddressingMode.Relative:
				{
					// ops with 8 bit arg
					uint value = Read8(address++);
					pOpcode.programCode[pOpcode.pcWords++] = cast(ubyte)value;

					++pOpcode.numArgs;
					if(addressMode == AddressingMode.Relative)
					{
						pOpcode.args[0].arg.format("$%04X", address + cast(byte)value); // calculate relative address
						pOpcode.args[0].value = address + cast(byte)value;
						pOpcode.args[0].type = DisassembledOp.Arg.Type.JumpTarget;
						pOpcode.flags |= DisassembledOp.Flags.Branch;
					}
					else if(addressMode == AddressingMode.Immediate)
					{
						pOpcode.args[0].arg.format("#$%02X", value);
						pOpcode.args[0].value = value;
						pOpcode.args[0].type = DisassembledOp.Arg.Type.Immediate;
					}
					else
					{
						pOpcode.args[0].arg.format("$%02X", value);
						pOpcode.args[0].value = value;
						pOpcode.args[0].type = DisassembledOp.Arg.Type.Address;

						if (op == Instruction.JMP || op == Instruction.JSR)
							pOpcode.args[0].type = DisassembledOp.Arg.Type.JumpTarget;
					}
					break;
				}

			case AddressingMode.AbsoluteX:
			case AddressingMode.AbsoluteY:
			case AddressingMode.Absolute:
			case AddressingMode.Indirect:
				{
					// ops with 16 bit arg
					uint value = Read16_LE(address);
					address += 2;

					pOpcode.programCode[pOpcode.pcWords++] = cast(ubyte)(value & 0xFF);
					pOpcode.programCode[pOpcode.pcWords++] = cast(ubyte)(value >> 8);

					++pOpcode.numArgs;
					pOpcode.args[0].arg.format("$%04X", value);
					pOpcode.args[0].value = value;
					pOpcode.args[0].type = (op == Instruction.JMP || op == Instruction.JSR) ? DisassembledOp.Arg.Type.JumpTarget : DisassembledOp.Arg.Type.ReadAddress;
					break;
				}
			default:
				break;
		};

		// some address modes have 2 args...
		switch(addressMode)
		{
			case AddressingMode.AbsoluteY:
			case AddressingMode.ZeroPageY:
			case AddressingMode.IndirectY:
				pOpcode.args[1].arg = "Y";
				pOpcode.args[1].value = 4;
				pOpcode.args[1].type = DisassembledOp.Arg.Type.Register;
				++pOpcode.numArgs;
				break;
			case AddressingMode.AbsoluteX:
			case AddressingMode.ZeroPageX:
			case AddressingMode.XIndirect:
				pOpcode.args[1].arg = "X";
				pOpcode.args[1].value = 3;
				pOpcode.args[1].type = DisassembledOp.Arg.Type.Register;
				++pOpcode.numArgs;
				break;
			default:
				break;
		}

		// figure out some useful flags
		if(op == Instruction.JMP || op == Instruction.RTS || op == Instruction.RTI || op == Instruction.BRK)
		{
			pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
			if(op == Instruction.JMP)
				pOpcode.flags |= DisassembledOp.Flags.Jump;
			else if(op == Instruction.RTS || op == Instruction.RTI)
				pOpcode.flags |= DisassembledOp.Flags.Return;
		}
		else if(op == Instruction.LDA || op == Instruction.LDX || op == Instruction.LDY)
		{
			pOpcode.flags |= DisassembledOp.Flags.Load;
			if(pOpcode.args[0].type == DisassembledOp.Arg.Type.Address)
				pOpcode.args[0].type = DisassembledOp.Arg.Type.ReadAddress;
		}
		else if(op == Instruction.STA || op == Instruction.STX || op == Instruction.STY)
		{
			pOpcode.flags |= DisassembledOp.Flags.Store;
			pOpcode.args[0].type = DisassembledOp.Arg.Type.WriteAddress;
		}
		else if (op == Instruction.JSR)
		{
			pOpcode.flags |= DisassembledOp.Flags.Branch;
		}
		else if (op == Instruction.BCC || op == Instruction.BCS || op == Instruction.BEQ || op == Instruction.BMI || op == Instruction.BNE || op == Instruction.BPL || op == Instruction.BVC || op == Instruction.BVS)
		{
			pOpcode.flags |= DisassembledOp.Flags.Conditional;
		}

		return pOpcode.pcWords;
	}

private:
	Registers registers;

	Version processorRevision;

	// support for pipeline simulation
	Instruction op;
	AddressingMode addressMode;
	int stage;
	int address;
	int operand;

	void FLAGNZ(int result) nothrow					{ registers.sr = (registers.sr & ~(SR_Negative | SR_Zero)) | ((result) & SR_Negative) | (!(result&0xFF) << 1); }
	void FLAGNZC(int result) nothrow				{ registers.sr = (registers.sr & ~(SR_Negative | SR_Zero | SR_Carry)) | ((result) & SR_Negative) | (!(result&0xFF) << 1) | ((result>>8) & SR_Carry); }
	void FLAGNZCV(int result, int operand) nothrow	{ registers.sr = (registers.sr & ~(SR_Negative | SR_Zero | SR_Carry | SR_Overflow)) | ((result) & SR_Negative) | (!(result&0xFF) << 1) | ((result>>8) & SR_Carry) | ((~(registers.ac ^ operand) & (registers.ac ^ result) & SR_Negative) >> 1); }
	void FLAGNZnCV(int result, int operand) nothrow	{ registers.sr = (registers.sr & ~(SR_Negative | SR_Zero | SR_Carry | SR_Overflow)) | ((result) & SR_Negative) | (!(result&0xFF) << 1) | (((~result)>>8) & SR_Carry)  | (((registers.ac ^ operand) & (registers.ac ^ result) & SR_Negative) >> 1); }

	ubyte Read8(uint address)
	{
		address &= procInfo.addressMask;
		return memmap.Read8(address);
	}

	void Write8(uint address, ubyte value)
	{
		address &= procInfo.addressMask;
		memmap.Write8(address, value);
	}

	ushort Read16_LE(uint address)
	{
		address &= procInfo.addressMask;
		return memmap.Read16_LE(address);
	}

	void Write16_LE(uint address, ushort value)
	{
		address &= procInfo.addressMask;
		memmap.Write16_LE(address, value);
	}
}

private:

// opcode data
struct Opcode
{
	Instruction op;
	AddressingMode addressingMode;
	int cycleCount;
}

// cpu registers
struct Registers
{
	ushort pc;  // program counter
	ubyte ac;   // accumulator
	ubyte x, y; // X, Y registers
	ubyte sr;   // status register
	ubyte sp;   // stack pointer
}

// status flags register
enum : ubyte
{
	SR_Carry = 0x01,
	SR_Zero = 0x02,
	SR_Interrupt = 0x04,
	SR_Decimal = 0x08,
	SR_Break = 0x10,
	SR_Unused = 0x20,
	SR_Overflow = 0x40,
	SR_Negative = 0x80,
}

// Registers.  Use with GetRegisterValue()
enum Regs
{
	PC,
	SP,
	AC,
	X,
	Y,
	SR,
}

enum Instruction
{
	UNK = -1, // unknown opcode

	// functions that operate only on an address
	BCC = 0, // branch on carry clear
	BCS, // branch on carry set
	BEQ, // branch on equal (zero set)
	BMI, // branch on minus (negative set)
	BNE, // branch on not equal (zero clear)
	BPL, // branch on plus (negative clear)
	BVC, // branch on overflow clear
	BVS, // branch on overflow set
	JMP, // jump
	JSR, // jump subroutine
	STA, // store accumulator
	STX, // store X
	STY, // store Y

	// functions that operate on an operand (require an additional operand lookup)
	ADC, // add with carry
	AND, // and (with accumulator)
	ASL, // arithmetic shift left
	BIT, // bit test
	BRK, // interrupt
	CLC, // clear carry
	CLD, // clear decimal
	CLI, // clear interrupt disable
	CLV, // clear overflow
	CMP, // compare (with accumulator)
	CPX, // compare with X
	CPY, // compare with Y
	DEC, // decrement
	DEX, // decrement X
	DEY, // decrement Y
	EOR, // exclusive or (with accumulator)
	INC, // increment
	INX, // increment X
	INY, // increment Y
	LDA, // load accumulator
	LDX, // load X
	LDY, // load Y
	LSR, // logical shift right
	NOP, // no operation
	ORA, // or with accumulator
	PHA, // push accumulator
	PHP, // push processor status (SR)
	PLA, // pull accumulator
	PLP, // pull processor status (SR)
	ROL, // rotate left
	ROR, // rotate right
	RTI, // return from interrupt
	RTS, // return from subroutine
	SBC, // subtract with carry
	SEC, // set carry
	SED, // set decimal
	SEI, // set interrupt disable
	TAX, // transfer accumulator to X
	TAY, // transfer accumulator to Y
	TSX, // transfer stack pointer to X
	TXA, // transfer X to accumulator
	TXS, // transfer X to stack pointer
	TYA, // transfer Y to accumulator

	Max
}

enum AddressingMode
{
	Unknown = -1,

	Implicit = 0,
	Accumulator,
	Immediate,
	ZeroPage,
	ZeroPageX,
	ZeroPageY,
	Absolute,
	AbsoluteX,
	AbsoluteY,
	Indirect,
	XIndirect,
	IndirectY,
	Relative,

	Max
}

// The 6510 has two special registers stored at memory location 0x0000 and 0x0001. They're on the processor,
// but just for neatness we'll store them in the machine's memory.
enum ProcessorPortFlags
{
	// TODO: These are most likely C64 specific, but I know of nothing else that uses the 6510. If something
	// else does pop up, this can easilly be moved over to the C64 machine.
	LOWRAM                     = 0x01,
	HIRAM                      = 0x02,
	CHAREN                     = 0x04,
	CassetteWrite              = 0x08,
	CassetteSwitch             = 0x10,
	CassetteMotor              = 0x20,

	DefaultDataDirectionValue  = 0x2F,
	DefaultPortValue           = 0x37,
}

enum MappedRegisters
{
	ProcessorPortDataDirection  = 0x0000,
	ProcessorPort               = 0x0001,
}

static immutable Opcode[] opcodeTable =
[
	Opcode( Instruction.BRK, AddressingMode.Implicit,    7 ),       // 0x00
	Opcode( Instruction.ORA, AddressingMode.XIndirect,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.ORA, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.ASL, AddressingMode.ZeroPage,    5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.PHP, AddressingMode.Implicit,    3 ),
	Opcode( Instruction.ORA, AddressingMode.Immediate,   2 ),
	Opcode( Instruction.ASL, AddressingMode.Accumulator, 2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.ORA, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.ASL, AddressingMode.Absolute,    6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ), //??

	Opcode( Instruction.BPL, AddressingMode.Relative,    2 ),       // 0x10
	Opcode( Instruction.ORA, AddressingMode.IndirectY,   5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.ORA, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.ASL, AddressingMode.ZeroPageX,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ), //??
	Opcode( Instruction.CLC, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.ORA, AddressingMode.AbsoluteY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.ORA, AddressingMode.AbsoluteX,   4 ),
	Opcode( Instruction.ASL, AddressingMode.AbsoluteX,   7 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ), //??

	Opcode( Instruction.JSR, AddressingMode.Absolute,    6 ),       // 0x20
	Opcode( Instruction.AND, AddressingMode.XIndirect,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.BIT, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.AND, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.ROL, AddressingMode.ZeroPage,    5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.PLP, AddressingMode.Implicit,    4 ),
	Opcode( Instruction.AND, AddressingMode.Immediate,   2 ),
	Opcode( Instruction.ROL, AddressingMode.Accumulator, 2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.BIT, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.AND, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.ROL, AddressingMode.Absolute,    6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.BMI, AddressingMode.Relative,    2 ),       // 0x30
	Opcode( Instruction.AND, AddressingMode.IndirectY,   5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.AND, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.ROL, AddressingMode.ZeroPageX,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ), //??
	Opcode( Instruction.SEC, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.AND, AddressingMode.AbsoluteY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.AND, AddressingMode.AbsoluteX,   4 ),
	Opcode( Instruction.ROL, AddressingMode.AbsoluteX,   7 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.RTI, AddressingMode.Implicit,    6 ),       // 0x40
	Opcode( Instruction.EOR, AddressingMode.XIndirect,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.EOR, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.LSR, AddressingMode.ZeroPage,    5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ), //??
	Opcode( Instruction.PHA, AddressingMode.Implicit,    3 ),
	Opcode( Instruction.EOR, AddressingMode.Immediate,   2 ),
	Opcode( Instruction.LSR, AddressingMode.Accumulator, 2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.JMP, AddressingMode.Absolute,    3 ),
	Opcode( Instruction.EOR, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.LSR, AddressingMode.Absolute,    6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.BVC, AddressingMode.Relative,    2 ),       // 0x50
	Opcode( Instruction.EOR, AddressingMode.IndirectY,   5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.EOR, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.LSR, AddressingMode.ZeroPageX,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ), //??
	Opcode( Instruction.CLI, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.EOR, AddressingMode.AbsoluteY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.EOR, AddressingMode.AbsoluteX,   4 ),
	Opcode( Instruction.LSR, AddressingMode.AbsoluteX,   7 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ), //??

	Opcode( Instruction.RTS, AddressingMode.Implicit,    6 ),       // 0x60
	Opcode( Instruction.ADC, AddressingMode.XIndirect,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.ADC, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.ROR, AddressingMode.ZeroPage,    5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ), //??
	Opcode( Instruction.PLA, AddressingMode.Implicit,    4 ),
	Opcode( Instruction.ADC, AddressingMode.Immediate,   2 ),
	Opcode( Instruction.ROR, AddressingMode.Accumulator, 2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.JMP, AddressingMode.Indirect,    5 ),
	Opcode( Instruction.ADC, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.ROR, AddressingMode.Absolute,    6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.BVS, AddressingMode.Relative,    2 ),       // 0x70
	Opcode( Instruction.ADC, AddressingMode.IndirectY,   5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.ADC, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.ROR, AddressingMode.ZeroPageX,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.SEI, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.ADC, AddressingMode.AbsoluteY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.ADC, AddressingMode.AbsoluteX,   4 ),
	Opcode( Instruction.ROR, AddressingMode.AbsoluteX,   7 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),       // 0x80
	Opcode( Instruction.STA, AddressingMode.XIndirect,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.STY, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.STA, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.STX, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.DEY, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.TXA, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.STY, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.STA, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.STX, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.BCC, AddressingMode.Relative,    2 ),       // 0x90
	Opcode( Instruction.STA, AddressingMode.IndirectY,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.STY, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.STA, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.STX, AddressingMode.ZeroPageY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.TYA, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.STA, AddressingMode.AbsoluteY,   5 ),
	Opcode( Instruction.TXS, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.STA, AddressingMode.AbsoluteX,   5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.LDY, AddressingMode.Immediate,   2 ),       // 0xA0
	Opcode( Instruction.LDA, AddressingMode.XIndirect,   6 ),
	Opcode( Instruction.LDX, AddressingMode.Immediate,   2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.LDY, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.LDA, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.LDX, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.TAY, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.LDA, AddressingMode.Immediate,   2 ),
	Opcode( Instruction.TAX, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.LDY, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.LDA, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.LDX, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.BCS, AddressingMode.Relative,    2 ),       // 0xB0
	Opcode( Instruction.LDA, AddressingMode.IndirectY,   5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.LDY, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.LDA, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.LDX, AddressingMode.ZeroPageY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.CLV, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.LDA, AddressingMode.AbsoluteY,   4 ),
	Opcode( Instruction.TSX, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.LDY, AddressingMode.AbsoluteX,   4 ),
	Opcode( Instruction.LDA, AddressingMode.AbsoluteX,   4 ),
	Opcode( Instruction.LDX, AddressingMode.AbsoluteY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.CPY, AddressingMode.Immediate,   2 ),       // 0xC0
	Opcode( Instruction.CMP, AddressingMode.XIndirect,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.CPY, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.CMP, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.DEC, AddressingMode.ZeroPage,    5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.INY, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.CMP, AddressingMode.Immediate,   2 ),
	Opcode( Instruction.DEX, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.CPY, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.CMP, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.DEC, AddressingMode.Absolute,    6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.BNE, AddressingMode.Relative,    2 ),       // 0xD0
	Opcode( Instruction.CMP, AddressingMode.IndirectY,   5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.CMP, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.DEC, AddressingMode.ZeroPageX,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.CLD, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.CMP, AddressingMode.AbsoluteY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.CMP, AddressingMode.AbsoluteX,   4 ),
	Opcode( Instruction.DEC, AddressingMode.AbsoluteX,   7 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.CPX, AddressingMode.Immediate,   2 ),       // 0xE0
	Opcode( Instruction.SBC, AddressingMode.XIndirect,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.CPX, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.SBC, AddressingMode.ZeroPage,    3 ),
	Opcode( Instruction.INC, AddressingMode.ZeroPage,    5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.INX, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.SBC, AddressingMode.Immediate,   2 ),
	Opcode( Instruction.NOP, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.CPX, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.SBC, AddressingMode.Absolute,    4 ),
	Opcode( Instruction.INC, AddressingMode.Absolute,    6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),

	Opcode( Instruction.BEQ, AddressingMode.Relative,    2 ),       // 0xF0
	Opcode( Instruction.SBC, AddressingMode.IndirectY,   5 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.SBC, AddressingMode.ZeroPageX,   4 ),
	Opcode( Instruction.INC, AddressingMode.ZeroPageX,   6 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.SED, AddressingMode.Implicit,    2 ),
	Opcode( Instruction.SBC, AddressingMode.AbsoluteY,   4 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 ),
	Opcode( Instruction.SBC, AddressingMode.AbsoluteX,   4 ),
	Opcode( Instruction.INC, AddressingMode.AbsoluteX,   7 ),
	Opcode( Instruction.UNK, AddressingMode.Unknown,     0 )
];

static string[AddressingMode.Max] pASMTemplate =
[
	"%s",         // AddressingMode.Implicit
	"%s %s",      // AddressingMode.Accumulator
	"%s %s",      // AddressingMode.Immediate
	"%s %s",      // AddressingMode.ZeroPage
	"%s %s,%s",   // AddressingMode.ZeroPageX
	"%s %s,%s",   // AddressingMode.ZeroPageY
	"%s %s",      // AddressingMode.Absolute
	"%s %s,%s",   // AddressingMode.AbsoluteX
	"%s %s,%s",   // AddressingMode.AbsoluteY
	"%s (%s)",    // AddressingMode.Indirect
	"%s (%s,%s)", // AddressingMode.XIndirect
	"%s (%s),%s", // AddressingMode.IndirectY
	"%s %s",      // AddressingMode.Relative
];

static string[Instruction.Max] pOpcodeNames =
[
	"BCC",
	"BCS",
	"BEQ",
	"BMI",
	"BNE",
	"BPL",
	"BVC",
	"BVS",
	"JMP",
	"JSR",
	"STA",
	"STX",
	"STY",
	"ADC",
	"AND",
	"ASL",
	"BIT",
	"BRK",
	"CLC",
	"CLD",
	"CLI",
	"CLV",
	"CMP",
	"CPX",
	"CPY",
	"DEC",
	"DEX",
	"DEY",
	"EOR",
	"INC",
	"INX",
	"INY",
	"LDA",
	"LDX",
	"LDY",
	"LSR",
	"NOP",
	"ORA",
	"PHA",
	"PHP",
	"PLA",
	"PLP",
	"ROL",
	"ROR",
	"RTI",
	"RTS",
	"SBC",
	"SEC",
	"SED",
	"SEI",
	"TAX",
	"TAY",
	"TSX",
	"TXA",
	"TXS",
	"TYA"
];

static immutable RegisterInfo[] sRegInfo =
[
	RegisterInfo( "PC", 16, RegisterInfo.Flags.ProgramCounter, null ),
	RegisterInfo( "SP", 8, RegisterInfo.Flags.StackPointer, null ),
	RegisterInfo( "A", 8, 0, null ),
	RegisterInfo( "X", 8, 0, null ),
	RegisterInfo( "Y", 8, 0, null ),
	RegisterInfo( "SR", 8, RegisterInfo.Flags.FlagsRegister, "NV.BDIZC" )
];

static immutable int[] sDisplayRegs = [ 2, 3, 4, 5, 1, 0 ];

static string[] sProcessorName =
[
	"MOS6502",
	"MOS6507",
	"MOS6510",
];

module demu.emulator.parts.cpu.z80;

import demu.emulator.machine;
import demu.emulator.memmap;
import demu.emulator.parts.part;
import demu.emulator.parts.processor;

import std.string;

class Z80 : Processor
{
	this(Machine machine, string name, MemMap memmap)
	{
		super(machine, name, Feature.Stack | Feature.Code | Feature.Registers);
		MemoryMap = memmap;

		procInfo.name = "Z80";
		procInfo.processorFamily = "Z80";
		procInfo.endian = Endian.Little;
		procInfo.addressWidth = 16;
		procInfo.addressMask = 0xFFFF;
		procInfo.stackOffset = 0;
		procInfo.opcodeWidth = 8;
		procInfo.maxOpwords = 4;
		procInfo.maxAsmLineLength = 15;

		regInfo = sRegInfo;
		displayRegs = sDisplayRegs;

		regs.SP = 0xFFFF;
		regs.A = regs.F = 0xFF;
		UpdateFlags();

		RegisterSymbols(sCodeLabels);
	}

	uint Reset()
	{
		startAddress = 0x0000; // z80 programs begin at 0x0000
		regs.PC = cast(ushort)startAddress;

		regs.IE = regs.IE2 = 0;
		regs.IM = 0;
		regs.I = regs.R = 0;

		regs.SP = 0xFFFF;
		regs.A = regs.F = 0xFF;
		UpdateFlags();

		return super.Reset();
	}

	void SetProgramCounter(uint pc) nothrow
	{
		regs.PC = cast(ushort)pc;
	}

	int Execute(int numCycles, uint breakConditions)
	{
		bYield = false;

		// try and prevent some LHSs
		int remainingCycles = numCycles;
		long l_cycleCount = cycleCount;
		ushort PC = regs.PC;

		do
		{
			bool bSupressInterrupts = false;
			long cc = l_cycleCount;
			waitCycles = 0;

			static if(EnableDissassembly)
			{
				// log the instruction stream
				DisassembledOp disOp = void;
				bool bDisOpValid = false;
				if(bLogExecution)
					bDisOpValid = !!DisassembleOpcode(PC, &disOp);
			}

			// read the next op at the program counter
			ubyte opcode = memmap.Read8(PC++ & procInfo.addressMask);
		handle_int_mode_0:

			// temp values
			ushort operandA = 0, operandB = 0;
			ushort targetA = 0, targetB = 0;
			int result = 0;

			// find the relevant opcode table
			immutable(Opcode)[] opcodeTable = null;
			Instruction op = Instruction.UNK;
			ubyte CBImm = 0;

			switch(opcode)
			{
				case 0xCB:
					opcode = memmap.Read8(PC++ & procInfo.addressMask);
					opcodeTable = opcodeTableCB;
					regs.R += 2;

					CBImm = (opcode >> 3) & 7; // look up the CB immediate arg
					opcode = (opcode & 7) | ((opcode >> 3) & 0x18); // remove the immediate bits
					op = cast(Instruction)opcodeTable[opcode].op;

					// the shift ops are packed
					if(op == Instruction.SHIFT)
						op = cbShift[CBImm];
					break;
				case 0xDD:
					opcode = memmap.Read8(PC++ & procInfo.addressMask);
					if(opcode == 0xCB)
					{
						// look up the index first
						targetA = cast(ushort)(regs.IX + cast(byte)memmap.Read8(PC++ & procInfo.addressMask));
						operandA = memmap.Read8(targetA & procInfo.addressMask);

						opcode = memmap.Read8(PC++ & procInfo.addressMask);
						opcodeTable = opcodeTableXXCB;

						CBImm = (opcode >> 3) & 7; // look up the CB immediate arg
						opcode = (opcode & 7) | ((opcode >> 3) & 0x18); // remove the immediate bits
						op = cast(Instruction)opcodeTable[opcode].op;

						// the shift ops are packed
						if(op == Instruction.SHIFT)
							op = cbShift[CBImm];
					}
					else
					{
						opcodeTable = opcodeTableDD;
						op = cast(Instruction)opcodeTable[opcode].op;
					}
					regs.R += 2;
					break;
				case 0xED:
					opcode = cast(ubyte)(memmap.Read8(PC++ & procInfo.addressMask) - 0x40);
					opcodeTable = opcodeTableED;
					if(opcode & 0x80) // HACK: We only store half the ED table
						opcode = 0x40; // Set to an illegal opcode in the ED table...
					op = cast(Instruction)opcodeTable[opcode].op;
					regs.R += 2;
					break;
				case 0xFD:
					opcode = memmap.Read8(PC++ & procInfo.addressMask);
					if(opcode == 0xCB)
					{
						// look up the index first
						targetA = cast(ushort)(regs.IY + cast(byte)memmap.Read8(PC++ & procInfo.addressMask));
						operandA = memmap.Read8(targetA & procInfo.addressMask);

						opcode = memmap.Read8(PC++ & procInfo.addressMask);
						opcodeTable = opcodeTableXXCB;

						CBImm = (opcode >> 3) & 7; // look up the CB immediate arg
						opcode = (opcode & 7) | ((opcode >> 3) & 0x18); // remove the immediate bits
						op = cast(Instruction)opcodeTable[opcode].op;

						// the shift ops are packed
						if(op == Instruction.SHIFT)
							op = cbShift[CBImm];
					}
					else
					{
						opcodeTable = opcodeTableFD;
						op = cast(Instruction)opcodeTable[opcode].op;
					}
					regs.R += 2;
					break;
				default:
					opcodeTable = sOpcodeTable;
					op = cast(Instruction)opcodeTable[opcode].op;
					++regs.R;
					break;
			}

			// lookup the opcode data from the opcode table
			ubyte arg1 = opcodeTable[opcode].arg1;
			ubyte arg2 = opcodeTable[opcode].arg2;

			// increment the cpu cycle count
			l_cycleCount += opcodeTable[opcode].cycleCount;
			cycleCount = l_cycleCount;

			// calculate the first operand
			if(arg1)
			{
				if(arg1 & 0x80)
				{
					switch(arg1 & 0x7)
					{
						case 0:
							// 8 bit immediate
							operandA = memmap.Read8(PC++ & procInfo.addressMask);
							break;
						case 1:
							// 16 bit immediate
							operandA = memmap.Read16_LE(PC & procInfo.addressMask);
							PC += 2;
							break;
						case 2:
							// relative address
							operandA = cast(ushort)(PC + cast(byte)memmap.Read8(PC & procInfo.addressMask) + 1);
							++PC;
							break;
						case 3:
							// index X
							operandA = cast(ushort)(regs.IX + cast(byte)memmap.Read8(PC++ & procInfo.addressMask));
							break;
						case 4:
							// index Y
							operandA = cast(ushort)(regs.IY + cast(byte)memmap.Read8(PC++ & procInfo.addressMask));
							break;
						default:
							// not defined!
							assert(false, "Shouldn't be here!");
							break;
					}
				}
				else
				{
					// 8 or 16 bit register
					if(arg1 & (AF_16b | AF_Ind))
					{
						targetA = arg1 & 0x0F;
						operandA = regs.reg16[targetA];
					}
					else
					{
						targetA = arg1 & 0x1F;
						operandA = GetReg8(targetA);
					}
				}

				// look up indirect arg
				if(arg1 & AF_Ind)
				{
					targetA = operandA;

					if(!(arg1 & AF_NR))
					{
						if(arg1 & AF_16b)
							operandA = memmap.Read16_LE(targetA & procInfo.addressMask);
						else
							operandA = memmap.Read8(targetA & procInfo.addressMask);
					}
				}
			}

			// calculate the second operand
			if(arg2)
			{
				if(arg2 & 0x80)
				{
					switch(arg2 & 0x7)
					{
						case 0:
							// 8 bit immediate
							operandB = memmap.Read8(PC++ & procInfo.addressMask);
							break;
						case 1:
							// 16 bit immediate
							operandB = memmap.Read16_LE(PC & procInfo.addressMask);
							PC += 2;
							break;
						case 2:
							// relative address
							operandB = cast(ushort)(PC + cast(byte)memmap.Read8(PC & procInfo.addressMask) + 1);
							++PC;
							break;
						case 3:
							// index X
							operandB = cast(ushort)(regs.IX + cast(byte)memmap.Read8(PC++ & procInfo.addressMask));
							break;
						case 4:
							// index Y
							operandB = cast(ushort)(regs.IY + cast(byte)memmap.Read8(PC++ & procInfo.addressMask));
							break;
						default:
							// not defined!
							assert(false, "Shouldn't be here!");
							break;
					}
				}
				else
				{
					// 8 or 16 bit register
					if(arg2 & (AF_16b | AF_Ind))
					{
						targetB = arg2 & 0x0F;
						operandB = regs.reg16[targetB];
					}
					else
					{
						targetB = arg2 & 0x1F;
						operandB = GetReg8(targetB);
					}
				}

				if(arg2 & AF_Ind)
				{
					targetB = operandB;

					if(!(arg2 & AF_NR))
					{
						if(arg2 & AF_16b)
							operandB = memmap.Read16_LE(targetB & procInfo.addressMask);
						else
							operandB = memmap.Read8(targetB & procInfo.addressMask);
					}
				}
			}

			// perform the operation
			switch(op) with(Instruction)
			{
				case ADC:
					result = operandA + operandB + regs.Fc;
					regs.A = cast(ubyte)result;

					regs.Fs = result & 0x80;
					regs.Fz = regs.A == 0;
					regs.Fn = 0;
					regs.Fh = ((operandA & 0xF) + (operandB & 0xF)) & 0x10;
					regs.Fv = ~(operandA ^ operandB) & (operandA ^ result) & 0x80;
					regs.Fc = (result >> 8) & 1;
					break;
				case ADC16:
					result = operandA + operandB + regs.Fc;
					regs.HL = cast(ushort)result;

					regs.Fs = (result >> 8) & 0x80;
					regs.Fz = regs.HL == 0;
					regs.Fn = 0;
					regs.Fh = 0; // undefined
					regs.Fv = (~(operandA ^ operandB) & (operandA ^ result) & 0x8000) >> 8;
					regs.Fc = (result >> 16) & 1;
					break;
				case ADD:
					result = operandA + operandB;
					regs.A = cast(ubyte)result;

					regs.Fs = result & 0x80;
					regs.Fz = regs.A == 0;
					regs.Fn = 0;
					regs.Fh = ((operandA & 0xF) + (operandB & 0xF)) & 0x10;
					regs.Fv = ~(operandA ^ operandB) & (operandA ^ result) & 0x80;
					regs.Fc = (result >> 8) & 1;
					break;
				case ADD16:
					result = operandA + operandB;
					regs.reg16[targetA] = cast(ushort)result;

					regs.Fn = 0;
					regs.Fh = 0; // undefined
					regs.Fc = (result >> 16) & 1;
					break;
				case AND:
					regs.A &= operandA;

					regs.Fs = regs.A & 0x80;
					regs.Fz = regs.A == 0;
					regs.Fn = regs.Fc = 0;
					regs.Fh = 0x10;
					regs.Fv = parityTable[regs.A];
					break;
				case BIT:
					result = operandA & (1 << CBImm);

					regs.Fz = !result;
					regs.Fn = 0;
					regs.Fh = 0x10;
					regs.Fs = regs.Fv = 0; // undefined
					break;
				case CALL:
					// DebugJumpToSub(PC, operandA, -1);
					memmap.Write16_LE((regs.SP - 2) & procInfo.addressMask, PC);
					regs.SP -= 2;
					PC = operandA;
					break;
				case CALLC:
					if(operandA)
					{
						// DebugJumpToSub(PC, operandB, -1);
						memmap.Write16_LE((regs.SP - 2) & procInfo.addressMask, PC);
						regs.SP -= 2;
						PC = operandB;
						l_cycleCount += 7;
						cycleCount = l_cycleCount;
					}
					break;
				case CALLNC:
					if(!operandA)
					{
						// DebugJumpToSub(PC, operandB, -1);
						regs.SP -= 2;
						memmap.Write16_LE(regs.SP & procInfo.addressMask, PC);
						PC = operandB;
						l_cycleCount += 7;
						cycleCount = l_cycleCount;
					}
					break;
				case CCF:
					regs.Fc ^= 1;
					regs.Fh ^= 0x10;
					regs.Fn = 0;
					break;
				case CP:
					result = regs.A - operandA;

					regs.Fz = (result & 0xFF) == 0;
					regs.Fs = result & 0x80;
					regs.Fc = (result >> 8) & 1;
					regs.Fv = (regs.A ^ operandA) & (regs.A ^ result) & 0x80;
					regs.Fh = (regs.A ^ operandA ^ result) & 0x10;
					regs.Fn = 1;
					break;
				case CPD:
					operandA = memmap.Read8(regs.HL-- & procInfo.addressMask);
					--regs.BC;

					result = regs.A - operandA;

					regs.Fz = (result & 0xFF) == 0;
					regs.Fs = result & 0x80;
					regs.Fv = regs.BC != 0;
					regs.Fh = (regs.A ^ operandA ^ result) & 0x10;
					regs.Fn = 1;
					break;
				case CPDR:
					operandA = memmap.Read8(regs.HL-- & procInfo.addressMask);

					result = (regs.A - operandA) & 0xFF;

					if(result && --regs.BC)
					{
						PC -= 2;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}

					regs.Fz = (result & 0xFF) == 0;
					regs.Fs = result & 0x80;
					regs.Fv = regs.BC != 0;
					regs.Fh = (regs.A ^ operandA ^ result) & 0x10;
					regs.Fn = 1;
					break;
				case CPI:
					operandA = memmap.Read8(regs.HL++ & procInfo.addressMask);
					--regs.BC;

					result = regs.A - operandA;

					regs.Fz = (result & 0xFF) == 0;
					regs.Fs = result & 0x80;
					regs.Fv = regs.BC != 0;
					regs.Fh = (regs.A ^ operandA ^ result) & 0x10;
					regs.Fn = 1;
					break;
				case CPIR:
					operandA = memmap.Read8(regs.HL++ & procInfo.addressMask);

					result = (regs.A - operandA) & 0xFF;

					if(result && --regs.BC)
					{
						PC -= 2;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}

					regs.Fz = (result & 0xFF) == 0;
					regs.Fs = result & 0x80;
					regs.Fv = regs.BC != 0;
					regs.Fh = (regs.A ^ operandA ^ result) & 0x10;
					regs.Fn = 1;
					break;
				case CPL:
					regs.A = ~regs.A;
					regs.Fh = 0x10;
					regs.Fn = 1;
					break;
				case DAA:
					ubyte addVal=0;
					ubyte low = regs.A&0xf;
					ubyte high = (regs.A&0xf0)>>4;

					if(!regs.Fn)                       // N=0 : Moving Up?
					{
						if(!regs.Fc)                                           // Carry was clear
						{
							if( (high<=0x08) && (!regs.Fh) && (low>=0x0a) )
								addVal = 0x06;
							else if( (high<=0x09) && (regs.Fh) && (low<=0x03) )
								addVal = 0x06;
							else if( (high>=0x0a) && (!regs.Fh) && (low<=0x09) )
								addVal = 0x60;
							else if( (high>=0x09) && (!regs.Fh) && (low>=0x0a) )
								addVal = 0x66;
							else if( (high>=0x0a) && (regs.Fh) && (low<=0x03) )
								addVal = 0x66;
						}
						else                                                        // Carry was set
						{
							if( (high<=0x02) && (!regs.Fh) && (low<=0x09) )
								addVal = 0x60;
							else if( (high<=0x02) && (!regs.Fh) && (low>=0x0a) )
								addVal = 0x66;
							else if( (high<=0x03) && (regs.Fh) && (low<=0x03) )
								addVal = 0x66;
						}
						regs.Fc = 0;
						if(addVal >= 0x60)
							regs.Fc = 1;
					}
					else                              // N=1 : Moving Down  (NOTE: carry remains as it was before)
					{
						if(!regs.Fc)
						{
							if(regs.Fh)
							{
								if( (high <= 0x08) && (low >= 0x06) )
									addVal = 0xfa;
							}
						}
						else                          // Carry was set
						{
							if(!regs.Fc)
							{
								if( (high >= 0x07) && (low <= 0x09) )
									addVal = 0xa0;
							}
							else                        // H=1
							{
								if( (high >= 0x06) && (low >= 0x06) )
									addVal = 0x9a;
							}
						}
					}
					regs.A = (regs.A+addVal)&0xFF;
					break;
				case DEC:
					result = GetReg8PreDec(targetA);
					result &= 0xFF;
					regs.Fz = (result == 0);
					regs.Fs = result & 0x80;
					regs.Fh = (result & 0xF) == 0xF;
					regs.Fv = (result == 0x7F);
					regs.Fn = 1;
					break;
				case DEC16:
					--regs.reg16[targetA];
					break;
				case DECi:
					result = operandA - 1;
					memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)result);
					result &= 0xFF;
					regs.Fz = (result == 0);
					regs.Fs = result & 0x80;
					regs.Fh = (result & 0xF) == 0xF;
					regs.Fv = (result == 0x7F);
					regs.Fn = 1;
					break;
				case DI:
					regs.IE = regs.IE2 = 0;
					break;
				case DJNZ:
					if(--regs.B)
					{
						PC = operandA;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}
					break;
				case EI:
					regs.IE = regs.IE2 = 1;
					bSupressInterrupts = true;
					break;
				case EX:
					result = regs.DE;
					regs.DE = regs.HL;
					regs.HL = cast(ushort)result;
					break;
				case EXaf:
					BuildFlags();
					result = regs.AF;
					regs.AF = regs.AF2;
					regs.AF2 = cast(ushort)result;
					UpdateFlags();
					break;
				case EXsp:
					result = memmap.Read16_LE(regs.SP & procInfo.addressMask);
					memmap.Write16_LE(regs.SP & procInfo.addressMask, regs.reg16[targetB]);
					regs.reg16[targetB] = cast(ushort)result;
					break;
				case EXX:
					result = regs.BC;
					regs.BC = regs.BC2;
					regs.BC2 = cast(ushort)result;
					result = regs.DE;
					regs.DE = regs.DE2;
					regs.DE2 = cast(ushort)result;
					result = regs.HL;
					regs.HL = regs.HL2;
					regs.HL2 = cast(ushort)result;
					break;
				case HALT:
					// The HALT instruction suspends CPU operation until a interrupt or reset is received.
					if(irqLineState == 0)
						--PC;

					// maybe we shouldn't do this, since this is sort of a valid op...
					//machine.DebugBreak("HALT instruction reached", HaltInstruction);
					break;
				case IM:
					regs.IM = arg1;
					break;

				case IN:
					// TOOD: split this into multiple ops for a bit more speed?
					if(arg2 == 0)
						result = memmap.IORead(operandA);
					else if (arg2 & Imm_8)
						result = SetReg8(targetA, memmap.IORead(operandB | (regs.A << 8)));
					else
						result = SetReg8(targetA, memmap.IORead(operandB));

					if(!(arg2 & AF_Imm))
					{
						regs.Fn = 0;
						regs.Fv = parityTable[result];
						regs.Fs = result & 0x80;
						regs.Fz = result == 0;
						//regs.Fh = 0; // TODO: ??
					}
					break;
				case INC:
					result = GetReg8PreInc(targetA) & 0xFF;
					regs.Fz = (result == 0);
					regs.Fs = result & 0x80;
					regs.Fh = (result & 0xF) == 0;
					regs.Fv = (result == 0x80);
					regs.Fn = 0;
					break;
				case INC16:
					result = ++regs.reg16[targetA];
					break;
				case INCi:
					result = (operandA + 1) & 0xFF;
					memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)result);

					regs.Fz = (result == 0);
					regs.Fs = result & 0x80;
					regs.Fh = (result & 0xF) == 0;
					regs.Fv = (result == 0x80);
					regs.Fn = 0;
					break;
				case IND:
					memmap.Write8(regs.HL-- & procInfo.addressMask, memmap.IORead(regs.C));

					regs.Fn = 1;
					regs.Fz = --regs.B == 0;
					break;
				case INDR:
					memmap.Write8(regs.HL-- & procInfo.addressMask, memmap.IORead(regs.C));

					if(--regs.B)
					{
						PC -= 2;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}

					regs.Fz = regs.Fn = 1;
					break;
				case INI:
					memmap.Write8(regs.HL++ & procInfo.addressMask, memmap.IORead(regs.C));

					regs.Fn = 1;
					regs.Fz = --regs.B == 0;
					break;
				case INIR:
					memmap.Write8(regs.HL++ & procInfo.addressMask, memmap.IORead(regs.C));

					if(--regs.B)
					{
						PC -= 2;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}

					regs.Fz = regs.Fn = 1;
					break;
				case JP:
				case JR:
					PC = operandA;
					break;
				case JPC:
					if(operandA)
						PC = operandB;
					break;
				case JRC:
					if(operandA)
					{
						PC = operandB;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}
					break;
				case JPNC:
					if(!operandA)
						PC = operandB;
					break;
				case JRNC:
					if(!operandA)
					{
						PC = operandB;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}
					break;
				case LD:
					SetReg8(targetA, cast(ubyte)operandB);
					break;
				case LD16:
					regs.reg16[targetA] = operandB;
					break;
				case LDi:
					memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandB);
					break;
				case LDi16:
					memmap.Write16_LE(targetA & procInfo.addressMask, operandB);
					break;
				case LDir:
					SetReg8(targetA, cast(ubyte)operandB);
					regs.Fz = operandB == 0;
					regs.Fs = operandB & 0x80;
					regs.Fh = regs.Fn = 0;
					regs.Fv = cast(ubyte)regs.IE;
					break;
				case LDD:
					memmap.Write8(regs.DE-- & procInfo.addressMask, memmap.Read8(regs.HL-- & procInfo.addressMask));
					regs.Fv = --regs.BC != 0;
					regs.Fh = regs.Fn = 0;
					break;
				case LDDR:
					memmap.Write8(regs.DE-- & procInfo.addressMask, memmap.Read8(regs.HL-- & procInfo.addressMask));
					if(--regs.BC)
					{
						PC -= 2;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}

					regs.Fv = regs.Fh = regs.Fn = 0;
					break;
				case LDI:
					memmap.Write8(regs.DE++ & procInfo.addressMask, memmap.Read8(regs.HL++ & procInfo.addressMask));
					regs.Fv = --regs.BC != 0;
					regs.Fh = regs.Fn = 0;
					break;
				case LDIR:
					memmap.Write8(regs.DE++ & procInfo.addressMask, memmap.Read8(regs.HL++ & procInfo.addressMask));
					if(--regs.BC)
					{
						PC -= 2;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}

					regs.Fv = regs.Fh = regs.Fn = 0;
					break;
				case NEG:
					regs.Fv = regs.A == 0x80;
					regs.Fz = regs.Fc = regs.A == 0;

					regs.A = cast(ubyte)(0 - regs.A);

					regs.Fs = regs.A & 0x80;
					regs.Fn = regs.Fh = 1;
					break;
				case NOP:
					// do nothing...
					break;
				case OR:
					regs.A |= operandA;

					regs.Fs = regs.A & 0x80;
					regs.Fz = regs.A == 0;
					regs.Fn = regs.Fc = regs.Fh = 0;
					regs.Fv = parityTable[regs.A];
					break;
				case OTDR:
					memmap.IOWrite(regs.C, memmap.Read8(regs.HL-- & procInfo.addressMask));
					if(--regs.B)
					{
						PC -= 2;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}

					regs.Fn = regs.Fz = 1;
					break;
				case OTIR:
					memmap.IOWrite(regs.C, memmap.Read8(regs.HL++ & procInfo.addressMask));
					if(--regs.B)
					{
						PC -= 2;
						l_cycleCount += 5;
						cycleCount = l_cycleCount;
					}

					regs.Fn = regs.Fz = 1;
					break;
				case OUT:
					if(arg1 & Imm_8)
						memmap.IOWrite(operandA | (regs.A << 8), cast(ubyte)operandB);
					else
						memmap.IOWrite(operandA, cast(ubyte)operandB);
					break;
				case OUTD:
					memmap.IOWrite(regs.C, memmap.Read8(regs.HL-- & procInfo.addressMask));

					regs.Fn = 1;
					regs.Fz = (--regs.B == 0);
					break;
				case OUTI:
					memmap.IOWrite(regs.C, memmap.Read8(regs.HL++ & procInfo.addressMask));

					regs.Fn = 1;
					regs.Fz = (--regs.B == 0);
					break;
				case POP:
					regs.reg16[targetA] = memmap.Read16_LE(regs.SP & procInfo.addressMask);
					regs.SP += 2;

					if(targetA == RO_AF)
						UpdateFlags();
					break;
				case PUSH:
					if(targetA == RO_AF)
						BuildFlags();

					regs.SP -= 2;
					memmap.Write16_LE(regs.SP & procInfo.addressMask, regs.reg16[targetA]);
					break;
				case RES:
					SetReg8(targetA, GetReg8(targetA) & ~(1 << CBImm));
					break;
				case RESi:
					operandA &= ~(1 << CBImm);
					memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);

					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case RET:
					PC = memmap.Read16_LE(regs.SP & procInfo.addressMask);
					regs.SP += 2;
					// DebugReturnFromSub(PC);
					break;
				case RETC:
					if(operandA)
					{
						PC = memmap.Read16_LE(regs.SP & procInfo.addressMask);
						regs.SP += 2;
						// DebugReturnFromSub(PC);
						l_cycleCount += 6;
						cycleCount = l_cycleCount;
					}
					break;
				case RETNC:
					if(!operandA)
					{
						PC = memmap.Read16_LE(regs.SP & procInfo.addressMask);
						regs.SP += 2;
						// DebugReturnFromSub(PC);
						l_cycleCount += 6;
						cycleCount = l_cycleCount;
					}
					break;
				case RETI:
					PC = memmap.Read16_LE(regs.SP & procInfo.addressMask);
					regs.SP += 2;
					// DebugReturnFromSub(PC);
					break;
				case RETN:
					regs.IE = regs.IE2;

					PC = memmap.Read16_LE(regs.SP & procInfo.addressMask);
					regs.SP += 2;
					// DebugReturnFromSub(PC);
					break;
				case RL:
					result = (operandA << 1) | regs.Fc;
					regs.Fc = operandA >> 8;
					result &= 0xFF;

					regs.Fh = regs.Fn = 0;
					regs.Fv = parityTable[result];
					regs.Fs = operandA & 0x80;
					regs.Fz = operandA == 0;

					if(!arg1 || (arg1 & AF_Ind))
						memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)result);
					else
						SetReg8(targetA, cast(ubyte)result);
					if(targetB)
						SetReg8(targetB, cast(ubyte)result);
					break;
				case RLA:
					result = regs.A << 1;
					regs.A = cast(ubyte)result | regs.Fc;
					regs.Fc = cast(ubyte)(result >> 8);

					regs.Fh = regs.Fn = 0;
					break;
				case RLC:
					regs.Fc = cast(ubyte)(operandA >> 7);
					operandA = ((operandA << 1) | regs.Fc) & 0xFF;

					regs.Fh = regs.Fn = 0;
					regs.Fv = parityTable[operandA];
					regs.Fs = operandA & 0x80;
					regs.Fz = operandA == 0;

					if(!arg1 || (arg1 & AF_Ind))
						memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);
					else
						SetReg8(targetA, cast(ubyte)operandA);
					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case RLCA:
					regs.Fc = regs.A >> 7;
					regs.A = cast(ubyte)((regs.A << 1) | regs.Fc);

					regs.Fh = regs.Fn = 0;
					break;
				case RLD:
					result = memmap.Read8(regs.HL & procInfo.addressMask);
					memmap.Write8(regs.HL & procInfo.addressMask, cast(ubyte)((regs.A & 0xF) | result << 4));
					regs.A = cast(ubyte)((regs.A & 0xF0) | (result >> 4));

					regs.Fs = regs.A & 0x80;
					regs.Fz = regs.A == 0;
					regs.Fv = parityTable[regs.A];
					regs.Fh = regs.Fn = 0;
					break;
				case RR:
					operandA |= regs.Fc << 8;
					regs.Fc = operandA & 1;
					operandA >>= 1;

					regs.Fh = regs.Fn = 0;
					regs.Fv = parityTable[operandA];
					regs.Fs = operandA & 0x80;
					regs.Fz = operandA == 0;

					if(!arg1 || (arg1 & AF_Ind))
						memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);
					else
						SetReg8(targetA, cast(ubyte)operandA);
					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case RRA:
					result = regs.A | (regs.Fc << 8);
					regs.Fc = regs.A & 1;
					regs.A = cast(ubyte)(result >> 1);

					regs.Fh = regs.Fn = 0;
					break;
				case RRC:
					regs.Fc = operandA & 1;
					operandA = (operandA >> 1) | (regs.Fc << 7);

					regs.Fh = regs.Fn = 0;
					regs.Fv = parityTable[operandA];
					regs.Fs = operandA & 0x80;
					regs.Fz = operandA == 0;

					if(!arg1 || (arg1 & AF_Ind))
						memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);
					else
						SetReg8(targetA, cast(ubyte)operandA);
					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case RRCA:
					regs.Fc = regs.A & 1;
					regs.A = cast(ubyte)((regs.A >> 1) | (regs.Fc << 7));

					regs.Fh = regs.Fn = 0;
					break;
				case RRD:
					result = memmap.Read8(regs.HL & procInfo.addressMask);
					memmap.Write8(regs.HL & procInfo.addressMask, cast(ubyte)((regs.A << 4) | result >> 4));
					regs.A = (regs.A & 0xF0) | (result & 0xF);

					regs.Fs = regs.A & 0x80;
					regs.Fz = regs.A == 0;
					regs.Fv = parityTable[regs.A];
					regs.Fh = regs.Fn = 0;
					break;
				case RST:
					regs.SP -= 2;
					memmap.Write16_LE(regs.SP & procInfo.addressMask, PC);

					PC = arg1 << 3;
					regs.R = 0;
					break;
				case SBC:
					result = operandA - operandB - regs.Fc;

					regs.Fz = (result & 0xFF) == 0;
					regs.Fs = result & 0x80;
					regs.Fc = (result >> 8) & 1;
					regs.Fv = (regs.A ^ operandB) & (regs.A ^ result) & 0x80;
					regs.Fh = (regs.A ^ operandB ^ result) & 0x10;
					regs.Fn = 1;

					regs.A = cast(ubyte)result;
					break;
				case SBC16:
					result = operandA - operandB - regs.Fc;

					regs.Fz = (result & 0xFFFF) == 0;
					regs.Fs = (result >> 8) & 0x80;
					regs.Fc = (result >> 16) & 1;
					regs.Fv = ((regs.HL ^ operandB) & (regs.HL ^ result) & 0x8000) >> 8;
					regs.Fh = 0; // undefined
					regs.Fn = 1;

					regs.HL = cast(ushort)result;
					break;
				case SCF:
					regs.Fc = 1;
					regs.Fh = regs.Fn = 0;
					break;
				case SET:
					SetReg8(targetA, GetReg8(targetA) | cast(ubyte)(1 << CBImm));
					break;
				case SETi:
					operandA |= 1 << CBImm;
					memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);

					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case SLA:
					regs.Fc = cast(ubyte)(operandA >> 7);
					operandA = (operandA << 1) & 0xFF;

					regs.Fh = regs.Fn = 0;
					regs.Fv = parityTable[operandA];
					regs.Fs = operandA & 0x80;
					regs.Fz = operandA == 0;

					if(!arg1 || (arg1 & AF_Ind))
						memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);
					else
						SetReg8(targetA, cast(ubyte)operandA);
					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case SLL:
					regs.Fc = cast(ubyte)(operandA >> 7);
					operandA = ((operandA << 1) | 1) & 0xFF;

					regs.Fh = regs.Fn = 0;
					regs.Fv = parityTable[operandA];
					regs.Fs = operandA & 0x80;
					regs.Fz = operandA == 0;

					if(!arg1 || (arg1 & AF_Ind))
						memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);
					else
						SetReg8(targetA, cast(ubyte)operandA);
					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case SRA:
					regs.Fc = operandA & 1;
					operandA = (operandA >> 1) | (operandA & 0x80);

					regs.Fh = regs.Fn = 0;
					regs.Fv = parityTable[operandA & 0xFF];
					regs.Fs = operandA & 0x80;
					regs.Fz = operandA == 0;

					if(!arg1 || (arg1 & AF_Ind))
						memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);
					else
						SetReg8(targetA, cast(ubyte)operandA);
					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case SRL:
					regs.Fc = operandA & 1;
					operandA = operandA >> 1;

					regs.Fh = regs.Fn = 0;
					regs.Fv = parityTable[operandA];
					regs.Fs = operandA & 0x80;
					regs.Fz = operandA == 0;

					if(!arg1 || (arg1 & AF_Ind))
						memmap.Write8(targetA & procInfo.addressMask, cast(ubyte)operandA);
					else
						SetReg8(targetA, cast(ubyte)operandA);
					if(targetB)
						SetReg8(targetB, cast(ubyte)operandA);
					break;
				case SUB:
					result = regs.A - operandA;

					regs.Fz = (result & 0xFF) == 0;
					regs.Fs = result & 0x80;
					regs.Fc = (result >> 8) & 1;
					regs.Fv = (regs.A ^ operandA) & (regs.A ^ result) & 0x80;
					regs.Fh = (regs.A ^ operandA ^ result) & 0x10;
					regs.Fn = 1;

					regs.A = cast(ubyte)result;
					break;
				case XOR:
					regs.A ^= operandA;

					regs.Fs = regs.A & 0x80;
					regs.Fz = regs.A == 0;
					regs.Fn = regs.Fc = regs.Fh = 0;
					regs.Fv = parityTable[regs.A];
					break;

				case UNK:
//					machine.DebugBreak("Illegal Opcode", BreakReason.IllegalOpcode);
					assert(false, "Unknown opcode!");
					break;
				default:
					// invalid opcode!
					assert(false, "Bad opcode?");
					break;
			}

			static if(EnableDissassembly)
			{
				if(bDisOpValid)
				{
					BuildFlags();
					WriteToLog(&disOp);
					bDisOpValid = false;
				}
			}

			// check for interrupts
			if(bNMIPending)
			{
				// DebugJumpToSub(PC, 0x66, 0);

				// store the interrupt enable flag
				regs.IE2 = regs.IE;
				regs.IE = 0;

				regs.SP -= 2;
				memmap.Write16_LE(regs.SP & procInfo.addressMask, PC);
				PC = 0x66;

				l_cycleCount += 11;
				cycleCount = l_cycleCount;
				regs.R += 3;

				bNMIPending = false;
			}
			else if(irqLineState && !bSupressInterrupts)
			{
				if(regs.IE)
				{
					// disable interrupts
					regs.IE = regs.IE2 = 0;

					// acknowledge interrupt
					uint intData = 0;
					if(intAckHandler)
						intData = intAckHandler(this);

					// do stuff
					switch(regs.IM)
					{
						case 0:
							// requires the machine to assert the next instruction on the bus, and the int should read it directly
							// since the code above will increment the PC, we'll dec it here to cancel it out
							opcode = cast(ubyte)intData;
							goto handle_int_mode_0;
						case 1:
							// DebugJumpToSub(PC, 0x38, 1);

							regs.SP -= 2;
							memmap.Write16_LE(regs.SP & procInfo.addressMask, PC);
							PC = 0x38;

							l_cycleCount += 13;
							cycleCount = l_cycleCount;
							regs.R += 3;
							break;
						case 2:
							regs.SP -= 2;
							memmap.Write16_LE(regs.SP & procInfo.addressMask, PC);

							// calculate the interrupt vector
							ushort intVector = cast(ushort)((regs.I << 8) | intData & 0xFF);

							// read the new PC
							PC = memmap.Read16_LE(intVector & procInfo.addressMask);

							l_cycleCount += 19;
							cycleCount = l_cycleCount;
							regs.R += 5;
							break;
						default:
							assert(false, "Invalid interrupt mode!");
							break;
					}
				}
			}

			l_cycleCount += waitCycles;
			cycleCount = l_cycleCount;
			remainingCycles -= cast(int)(l_cycleCount - cc);
			++opCount;
		}
		while(remainingCycles > 0 && !bYield);

		regs.PC = PC;

		// return the number of cycles actually executed
		return numCycles - remainingCycles;
	}

	uint GetRegisterValue(int reg)
	{
		switch(reg)
		{
			case 0: return regs.PC;
			case 1: return regs.SP;
			case 2:
				BuildFlags();
				return regs.AF;
			case 3: return regs.BC;
			case 4: return regs.DE;
			case 5: return regs.HL;
			case 6: return regs.IX;
			case 7: return regs.IY;
			case 8:
				BuildFlags();
				return regs.F;
			case 9: return regs.AF2;
			case 10: return regs.BC2;
			case 11: return regs.DE2;
			case 12: return regs.HL2;
			case 13: return regs.F2;
			case 14: return regs.I;
			case 15: return regs.R;
			case 16: return regs.IM;
			default:
				break;
		}
		return -1;
	}

	void SetRegisterValue(int reg, uint value)
	{
		switch(reg)
		{
			case 0: regs.PC = cast(ushort)value; break;
			case 1: regs.SP = cast(ushort)value; break;
			case 2:
				regs.AF = cast(ushort)value;
				UpdateFlags();
				break;
			case 3: regs.BC = cast(ushort)value; break;
			case 4: regs.DE = cast(ushort)value; break;
			case 5: regs.HL = cast(ushort)value; break;
			case 6: regs.IX = cast(ushort)value; break;
			case 7: regs.IY = cast(ushort)value; break;
			case 8:
				regs.F = cast(ubyte)value;
				UpdateFlags();
				break;
			case 9: regs.AF2 = cast(ushort)value; break;
			case 10: regs.BC2 = cast(ushort)value; break;
			case 11: regs.DE2 = cast(ushort)value; break;
			case 12: regs.HL2 = cast(ushort)value; break;
			case 13: regs.F2 = cast(ubyte)value; break;
			case 14: regs.I = cast(ubyte)value; break;
			case 15: regs.R = cast(ubyte)value; break;
			//case 16: regs.IM = cast(ubyte)value; break;
			default:
				break;
		}
	}

	static if(EnableDissassembly)
	{
		int DisassembleOpcode(uint address, DisassembledOp* pOpcode)
		{
			*pOpcode = DisassembledOp.init;
			pOpcode.programOffset = address & procInfo.addressMask;
			pOpcode.lineTemplate = "%s";

			// temp values
			ushort operandA, operandB;
			const(Opcode)[] pOpcodeTable;
			Instruction op = Instruction.UNK;
			ubyte CBImm;

			// read the next op at the program counter
			ubyte opcode = memmap.Read8(address++ & procInfo.addressMask);
			pOpcode.programCode[pOpcode.pcWords++] = opcode;

			// parse the complex Z80 opcodes
			switch(opcode)
			{
				case 0xCB:
					// handle CB as a special case
					opcode = memmap.Read8(address++ & procInfo.addressMask);
					pOpcode.programCode[pOpcode.pcWords++] = opcode;

					CBImm = (opcode >> 3) & 7; // look up the CB immediate arg
					opcode = (opcode & 7) | ((opcode >> 3) & 0x18); // remove the immediate bits
					op = cast(Instruction)opcodeTableCB[opcode].op;

					pOpcode.lineTemplate ~= " ";

					// the shift ops are packed
					if(op == Instruction.SHIFT)
						op = cbShift[CBImm];
					else
					{
						AddLiteralArgument(pOpcode, CBImm, false);
						pOpcode.lineTemplate ~= ",";
					}
					AddArgument(pOpcode, address, opcodeTableCB[opcode].arg1);

					pOpcode.instructionName = sOpcodeNames[op];
					return pOpcode.pcWords;
				case 0xDD:
				case 0xFD:
					ubyte opcode2 = memmap.Read8(address++ & procInfo.addressMask);
					pOpcode.programCode[pOpcode.pcWords++] = opcode2;

					if(opcode2 == 0xCB)
					{
						ubyte arg1 = opcode == 0xDD ? Idx_IX : Idx_IY;

						// handle XXCB as a special case
						ubyte programByte = memmap.Read8(address + 1 & procInfo.addressMask);
						opcode = programByte;

						CBImm = (opcode >> 3) & 7; // look up the CB immediate arg
						opcode = (opcode & 7) | ((opcode >> 3) & 0x18); // remove the immediate bits
						op = cast(Instruction)opcodeTableXXCB[opcode].op;

						pOpcode.lineTemplate ~= " ";

						// the shift ops are packed
						if(op == Instruction.SHIFT)
							op = cbShift[CBImm];
						else
						{
							AddLiteralArgument(pOpcode, CBImm, false);
							pOpcode.lineTemplate ~= ",";
						}
						AddArgument(pOpcode, address, arg1);

						if(opcodeTableXXCB[opcode].arg2)
						{
							pOpcode.lineTemplate ~= "->";
							AddArgument(pOpcode, address, opcodeTableXXCB[opcode].arg2);
						}

						pOpcode.programCode[pOpcode.pcWords++] = programByte;

						pOpcode.instructionName = sOpcodeNames[op];
						return pOpcode.pcWords;
					}
					else
					{
						pOpcodeTable = opcode == 0xDD ? opcodeTableDD : opcodeTableFD;
						op = cast(Instruction)pOpcodeTable[opcode2].op;
						opcode = opcode2;
					}
					break;
				case 0xED:
					opcode = memmap.Read8(address++ & procInfo.addressMask);
					pOpcode.programCode[pOpcode.pcWords++] = opcode;
					pOpcodeTable = opcodeTableED;

					opcode -= 0x40;
					if(opcode & 0x80) // HACK: We only store half the ED table
						opcode = 0x40; // Set to an illegal opcode in the ED table...
					op = cast(Instruction)pOpcodeTable[opcode].op;
					break;
				default:
					pOpcodeTable = sOpcodeTable;
					op = cast(Instruction)pOpcodeTable[opcode].op;
					break;
			}

			// check it was a valid opcode
			if(op == Instruction.UNK)
				return 0;

			// copy the instruction name
			pOpcode.instructionName = sOpcodeNames[op];

			// lookup the opcode data from the opcode table
			ubyte arg1 = pOpcodeTable[opcode].arg1;
			ubyte arg2 = pOpcodeTable[opcode].arg2;

			// special case ops
			switch(op)
			{
				// these instructions have a single constant argument
				case Instruction.RST:
					pOpcode.lineTemplate ~= " ";
					AddLiteralArgument(pOpcode, arg1 << 3, true); // arg is a multiple of 8
					return pOpcode.pcWords;
				case Instruction.IM:
					pOpcode.lineTemplate ~= " ";
					AddLiteralArgument(pOpcode, arg1, false);
					return pOpcode.pcWords;

					// IN and OUT treat an 8 bit register like its an indirect target
				case Instruction.IN:
					if(arg2)
					{
						pOpcode.lineTemplate ~= " ";
						AddArgument(pOpcode, address, arg1);
						pOpcode.lineTemplate ~= ",(";
						AddArgument(pOpcode, address, arg2);
						pOpcode.lineTemplate ~= ")";
						if(arg2 & AF_Imm)
							pOpcode.args[1].type = DisassembledOp.Arg.Type.ReadPort;
					}
					else
					{
						pOpcode.lineTemplate ~= " (";
						AddArgument(pOpcode, address, arg1);
						pOpcode.lineTemplate ~= ")";
						if(arg1 & AF_Imm)
							pOpcode.args[0].type = DisassembledOp.Arg.Type.ReadPort;
					}
					return pOpcode.pcWords;
				case Instruction.OUT:
					pOpcode.lineTemplate ~= " (";
					AddArgument(pOpcode, address, arg1);
					pOpcode.lineTemplate ~= "),";
					if(arg2)
						AddArgument(pOpcode, address, arg2);
					else
						AddLiteralArgument(pOpcode, 0, false);
					if(arg1 & AF_Imm)
						pOpcode.args[0].type = DisassembledOp.Arg.Type.WritePort;
					return pOpcode.pcWords;
				default:
					break;
			}

			// disassemble the args
			if(arg1)
			{
				pOpcode.lineTemplate ~= " ";
				AddArgument(pOpcode, address, arg1);

				if(arg2)
				{
					pOpcode.lineTemplate ~= ",";
					AddArgument(pOpcode, address, arg2);
				}
			}

			// figure out some useful info
			switch(op)
			{
				// return ops may have a condition
				case Instruction.RETNC:
					arg1 += 6;
				case Instruction.RETC:
					pOpcode.args[0].type = DisassembledOp.Arg.Type.Condition;
					pOpcode.args[0].arg = g8BitRegs[arg1];
					pOpcode.args[0].value = 0;
					pOpcode.flags |= DisassembledOp.Flags.Return;
					break;

					// branches have conditions
				case Instruction.JPNC:
				case Instruction.JRNC:
					arg1 += 6;
				case Instruction.JPC:
				case Instruction.JRC:
					pOpcode.args[1].type = DisassembledOp.Arg.Type.JumpTarget;
					pOpcode.args[0].type = DisassembledOp.Arg.Type.Condition;
					pOpcode.args[0].arg = g8BitRegs[arg1];
					pOpcode.args[0].value = 0;
					pOpcode.flags |= DisassembledOp.Flags.Branch;
					break;

					// call should resolve jump targets
				case Instruction.CALL:
					pOpcode.args[0].type = DisassembledOp.Arg.Type.JumpTarget;
					break;

					// branches may have conditions
				case Instruction.CALLNC:
					arg1 += 6;
				case Instruction.CALLC:
					pOpcode.args[1].type = DisassembledOp.Arg.Type.JumpTarget;
					pOpcode.args[0].type = DisassembledOp.Arg.Type.Condition;
					pOpcode.args[0].arg = g8BitRegs[arg1];
					pOpcode.args[0].value = 0;
					break;

					// returns have some flags
				case Instruction.RET:
				case Instruction.RETI:
				case Instruction.RETN:
					pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
					pOpcode.flags |= DisassembledOp.Flags.Return;
					break;

					// absolute jumps end functions
				case Instruction.JP:
					pOpcode.args[0].type = DisassembledOp.Arg.Type.JumpTarget;
				case Instruction.JR:
					pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
					pOpcode.flags |= DisassembledOp.Flags.Jump;
					break;

					// loads may read from memory
				case Instruction.LD:
				case Instruction.LD16:
					if(arg2 & AF_Ind)
						pOpcode.flags |= DisassembledOp.Flags.Load;
					break;

					// stores may write to memory
				case Instruction.LDi:
				case Instruction.LDi16:
					pOpcode.flags |= DisassembledOp.Flags.Store;
					if(pOpcode.args[0].type == DisassembledOp.Arg.Type.ReadAddress)
						pOpcode.args[0].type = DisassembledOp.Arg.Type.WriteAddress;
					if(arg2 & AF_Ind)
						pOpcode.flags |= DisassembledOp.Flags.Load;
					break;

				case Instruction.HALT:
					pOpcode.flags |= DisassembledOp.Flags.EndOfSequence;
					break;
				default:
					break;
			}

			return pOpcode.pcWords;
		}
	}

protected:
	Registers regs;

	// accessors for accessing generic regs as 8bit endian safe..
	version(BigEndian)
	{
		ubyte GetReg8(int index) const nothrow { return regs.raw_reg8[index^1]; }
		ubyte GetReg8PreInc(int index) nothrow { return ++regs.raw_reg8[index^1]; }
		ubyte GetReg8PreDec(int index) nothrow { return --regs.raw_reg8[index^1]; }
		ubyte GetReg8PostInc(int index) nothrow { return regs.raw_reg8[index^1]++; }
		ubyte GetReg8PostDec(int index) nothrow { return regs.raw_reg8[index^1]--; }
		ubyte SetReg8(int index, ubyte value) nothrow { return regs.raw_reg8[index^1] = value; }
	}
	else
	{
		ubyte GetReg8(int index) const nothrow { return regs.raw_reg8[index]; }
		ubyte GetReg8PreInc(int index) nothrow { return ++regs.raw_reg8[index]; }
		ubyte GetReg8PreDec(int index) nothrow { return --regs.raw_reg8[index]; }
		ubyte GetReg8PostInc(int index) nothrow { return regs.raw_reg8[index]++; }
		ubyte GetReg8PostDec(int index) nothrow { return regs.raw_reg8[index]--; }
		ubyte SetReg8(int index, ubyte value) nothrow { return regs.raw_reg8[index] = value; }
	}

	void BuildFlags() nothrow
	{
		regs.F = (regs.Fc ? 0x01 : 0) |
			(regs.Fn ? 0x02 : 0) |
			(regs.Fv ? 0x04 : 0) |
			(regs.Fh ? 0x10 : 0) |
			(regs.Fz ? 0x40 : 0) |
			(regs.Fs ? 0x80 : 0);
	}

	void UpdateFlags() nothrow
	{
		regs.Fs = regs.F & 0x80;
		regs.Fz = regs.F & 0x40;
		regs.Fh = regs.F & 0x10;
		regs.Fv = regs.F & 0x04;
		regs.Fn = regs.F & 0x02;
		regs.Fc = regs.F & 0x01;
	}

	static if(EnableDissassembly)
	{
		int AddLiteralArgument(DisassembledOp *pOpcode, int constant, bool bHex)
		{
			int argIndex = pOpcode.numArgs++;
			DisassembledOp.Arg* arg = &pOpcode.args[argIndex];

			arg.value = constant;
			arg.type = DisassembledOp.Arg.Type.Constant;
			if(bHex)
			{
				pOpcode.lineTemplate ~= "%s";
				arg.arg.format("$%X", constant);
			}
			else
			{
				pOpcode.lineTemplate ~= "%s";
				arg.arg.format("%d", constant);
			}

			return argIndex;
		}

		int AddArgument(DisassembledOp *pOpcode, ref uint address, ubyte arg)
		{
			int argIndex = pOpcode.numArgs++;
			DisassembledOp.Arg* pArg = &pOpcode.args[argIndex];

			string syntax;

			if(arg & AF_Imm)
			{
				switch(arg & 0x7)
				{
					case 0:
						ubyte imm = memmap.Read8(address++ & procInfo.addressMask);
						pOpcode.programCode[pOpcode.pcWords++] = imm;
						pArg.arg.format("$%02X", imm);
						pArg.value = imm;
						pArg.type = DisassembledOp.Arg.Type.Immediate;
						syntax = "%s";
						break;

					case 1:
						// 16 bit immediate
						ushort imm = memmap.Read16_LE(address & procInfo.addressMask);
						address += 2;
						pOpcode.programCode[pOpcode.pcWords++] = cast(ubyte)imm;
						pOpcode.programCode[pOpcode.pcWords++] = imm >> 8;
						pArg.arg.format("$%04X", imm);
						pArg.value = imm;
						pArg.type = (arg & AF_Ind) ? DisassembledOp.Arg.Type.ReadAddress : DisassembledOp.Arg.Type.Immediate;
						syntax = "%s";
						break;

					case 2:
						// relative address
						byte offset = cast(byte)memmap.Read8(address++ & procInfo.addressMask);
						pOpcode.programCode[pOpcode.pcWords++] = cast(ubyte)offset;
						pArg.arg.format("$%04X", address + offset);
						pArg.value = address + offset;
						pArg.type = DisassembledOp.Arg.Type.JumpTarget;
						syntax = "%s";
						break;

					case 3:
						// index X
						pArg.arg = "IX";
						pArg.type = DisassembledOp.Arg.Type.Register;
						pArg.value = g16BitRegIndexTable[RO_IX];

						pArg = &pOpcode.args[pOpcode.numArgs++];
						byte offset = cast(byte)memmap.Read8(address++ & procInfo.addressMask);
						pOpcode.programCode[pOpcode.pcWords++] = cast(ubyte)offset;
						pArg.arg.format("%d", offset);
						pArg.value = cast(uint)cast(int)offset;
						pArg.type = DisassembledOp.Arg.Type.Constant;
						syntax = "%s+%s";
						break;

					case 4:
						// index Y
						pArg.arg = "IY";
						pArg.type = DisassembledOp.Arg.Type.Register;
						pArg.value = g16BitRegIndexTable[RO_IY];

						pArg = &pOpcode.args[pOpcode.numArgs++];
						byte offset = cast(byte)memmap.Read8(address++ & procInfo.addressMask);
						pOpcode.programCode[pOpcode.pcWords++] = cast(ubyte)offset;
						pArg.arg.format("%d", offset);
						pArg.value = cast(uint)cast(int)offset;
						pArg.type = DisassembledOp.Arg.Type.Constant;
						syntax = "%s+%s";
						break;

					default:
						// not defined!
						assert(false, "Shouldn't be here!");
						break;
				}
			}
			else
			{
				if(arg & (AF_16b | AF_Ind))
				{
					pArg.arg = g16BitRegs[arg & 0x0F];
					pArg.value = g16BitRegIndexTable[arg & 0x0F];
					syntax = (arg & AF_Ind) ? "(%s)" : "%s";
				}
				else
				{
					pArg.arg = g8BitRegs[arg & 0x1F];
					pArg.value = 0; // we don't have discreet 8 bit registers... maybe we should add them?
					syntax = "%s";
				}
				pArg.type = DisassembledOp.Arg.Type.Register;
			}

			pOpcode.lineTemplate ~= syntax;

			return argIndex;
		}
	}
}

private:

// system structs
struct Opcode
{
	ubyte op;
	ubyte cycleCount;
	ubyte arg1, arg2;
}

struct Registers
{
	union
	{
		// explicit registers
		struct
		{
			ushort PC;
			ushort SP;

			union
			{
				struct
				{
					ushort AF;
					ushort BC;
					ushort DE;
					ushort HL;
					ushort IX;
					ushort IY;
					ushort IR;

					ushort AF2;
					ushort BC2;
					ushort DE2;
					ushort HL2;
				}

				version(BigEndian)
				{
					struct
					{
						ubyte A, F;
						ubyte B, C;
						ubyte D, E;
						ubyte H, L;
						ubyte IXH, IXL;
						ubyte IYH, IYL;
						ubyte I, R;

						ubyte A2, F2;
						ubyte B2, C2;
						ubyte D2, E2;
						ubyte H2, L2;
					}
				}
				else
				{
					struct
					{
						ubyte F, A;
						ubyte C, B;
						ubyte E, D;
						ubyte L, H;
						ubyte IXL, IXH;
						ubyte IYL, IYH;
						ubyte R, I;

						ubyte F2, A2;
						ubyte C2, B2;
						ubyte E2, D2;
						ubyte L2, H2;
					}
				}
			}

			version(BigEndian)
				ubyte Fz, Fs, Fv, Fh, Fc, Fn;
			else
				ubyte Fs, Fz, Fh, Fv, Fn, Fc;
		}

		// indexable 16 bit regs
		ushort reg16[16];

		// indexable 8 bit regs - do not access these directly as its not endian safe - use GetReg8, SetReg8
		ubyte raw_reg8[32];
	}

	int IE, IE2; // interrupt enable
	int IM; // interrupt mode
}

// offsets for indexing registers
// 16 bit registers
enum
{
	RO_PC = Registers.PC.offsetof >> 1,
	RO_SP = Registers.SP.offsetof >> 1,
	RO_AF = Registers.AF.offsetof >> 1,
	RO_BC = Registers.BC.offsetof >> 1,
	RO_DE = Registers.DE.offsetof >> 1,
	RO_HL = Registers.HL.offsetof >> 1,
	RO_IX = Registers.IX.offsetof >> 1,
	RO_IY = Registers.IY.offsetof >> 1,
	RO_AF2 = Registers.AF2.offsetof >> 1,
}
// 8 bit registers
version(BigEndian)
{
	enum
	{
		RO_A = Registers.A.offsetof^1,
		RO_B = Registers.B.offsetof^1,
		RO_C = Registers.C.offsetof^1,
		RO_D = Registers.D.offsetof^1,
		RO_E = Registers.E.offsetof^1,
		RO_H = Registers.H.offsetof^1,
		RO_L = Registers.L.offsetof^1,
		RO_IXH = Registers.IXH.offsetof^1,
		RO_IXL = Registers.IXL.offsetof^1,
		RO_IYH = Registers.IYH.offsetof^1,
		RO_IYL = Registers.IYL.offsetof^1,
		RO_I = Registers.I.offsetof^1,
		RO_R = Registers.R.offsetof^1,

		RO_Fs = Registers.Fs.offsetof^1,
		RO_Fz = Registers.Fz.offsetof^1,
		RO_Fh = Registers.Fh.offsetof^1,
		RO_Fv = Registers.Fv.offsetof^1,
		RO_Fn = Registers.Fn.offsetof^1,
		RO_Fc = Registers.Fc.offsetof^1
	}
}
else
{
	enum
	{
		RO_A = Registers.A.offsetof,
		RO_B = Registers.B.offsetof,
		RO_C = Registers.C.offsetof,
		RO_D = Registers.D.offsetof,
		RO_E = Registers.E.offsetof,
		RO_H = Registers.H.offsetof,
		RO_L = Registers.L.offsetof,
		RO_IXH = Registers.IXH.offsetof,
		RO_IXL = Registers.IXL.offsetof,
		RO_IYH = Registers.IYH.offsetof,
		RO_IYL = Registers.IYL.offsetof,
		RO_I = Registers.I.offsetof,
		RO_R = Registers.R.offsetof,

		RO_Fs = Registers.Fs.offsetof,
		RO_Fz = Registers.Fz.offsetof,
		RO_Fh = Registers.Fh.offsetof,
		RO_Fv = Registers.Fv.offsetof,
		RO_Fn = Registers.Fn.offsetof,
		RO_Fc = Registers.Fc.offsetof
	}
}

enum
{
	// argument flags
	AF_16b = 0x20, // 16 bit register
	AF_Ind = 0x40, // indirect lookup
	AF_Imm = 0x80, // 8, 16, rel, IXn, IYn,
	AF_NR  = 0x10, // no read, for indirect output

	// 16 bit registers
	Reg_PC = RO_PC | AF_16b,
	Reg_SP = RO_SP | AF_16b,
	Reg_AF = RO_AF | AF_16b,
	Reg_BC = RO_BC | AF_16b,
	Reg_DE = RO_DE | AF_16b,
	Reg_HL = RO_HL | AF_16b,
	Reg_IX = RO_IX | AF_16b,
	Reg_IY = RO_IY | AF_16b,

	// secondary registers
	Reg_AF2 = RO_AF2 | AF_16b,

	// 8 bit registers
	Reg_A  = RO_A,
	Reg_B  = RO_B,
	Reg_C  = RO_C,
	Reg_D  = RO_D,
	Reg_E  = RO_E,
	Reg_H  = RO_H,
	Reg_L  = RO_L,
	Reg_IXH = RO_IXH,
	Reg_IXL = RO_IXL,
	Reg_IYH = RO_IYH,
	Reg_IYL = RO_IYL,
	Reg_I  = RO_I,
	Reg_R  = RO_R,

	// conditions
	Cnd_C  = RO_Fc,
	Cnd_Z  = RO_Fz,
	Cnd_PE = RO_Fv,
	Cnd_M  = RO_Fs,

	// immediates
	Imm_8  = AF_Imm | 0,
	Imm_16 = AF_Imm | 1 | AF_16b,

	// relative
	Rel_16 = AF_Imm | 2 | AF_16b,

	// 8 bit indirects
	Ind_8  = AF_Imm | 1 | AF_Ind,
	Ind_SP8 = RO_HL | AF_Ind,
	Ind_BC8 = RO_BC | AF_Ind,
	Ind_DE8 = RO_DE | AF_Ind,
	Ind_HL8 = RO_HL | AF_Ind,
	Ind_IX8 = RO_IX | AF_Ind,
	Ind_IY8 = RO_IY | AF_Ind,

	// 16 bit indirects
	Ind_16 = AF_Imm | 1 | AF_Ind | AF_16b,
	Ind_SP = RO_HL | AF_Ind | AF_16b,
	Ind_BC = RO_BC | AF_Ind | AF_16b,
	Ind_DE = RO_DE | AF_Ind | AF_16b,
	Ind_HL = RO_HL | AF_Ind | AF_16b,
	Ind_IX = RO_IX | AF_Ind | AF_16b,
	Ind_IY = RO_IY | AF_Ind | AF_16b,

	// output only indirects
	Out_8  = AF_Imm | 0 | AF_Ind | AF_NR,
	Out_16 = AF_Imm | 1 | AF_Ind | AF_NR,
	Out_SP = RO_HL | AF_Ind | AF_NR,
	Out_BC = RO_BC | AF_Ind | AF_NR,
	Out_DE = RO_DE | AF_Ind | AF_NR,
	Out_HL = RO_HL | AF_Ind | AF_NR,
	Out_IX = RO_IX | AF_Ind | AF_NR,
	Out_IY = RO_IY | AF_Ind | AF_NR,

	// indexed
	Idx_IX  = AF_Imm | 3 | AF_Ind | AF_16b,
	Idx_IX8 = AF_Imm | 3 | AF_Ind,
	Idx_IY  = AF_Imm | 4 | AF_Ind | AF_16b,
	Idx_IY8 = AF_Imm | 4 | AF_Ind,

	// output only indexed
	Odx_IX = AF_Imm | 3 | AF_Ind | AF_NR,
	Odx_IY = AF_Imm | 4 | AF_Ind | AF_NR
}

// opcode list
enum Instruction
{
	UNK = cast(ubyte)-1, // unknown opcode

	ADC = 0,
	ADC16,
	ADD,
	ADD16,
	AND,
	BIT,
	CALL,
	CALLC,
	CALLNC,
	CCF,
	CP,
	CPD,
	CPDR,
	CPI,
	CPIR,
	CPL,
	DAA,
	DEC,
	DEC16,
	DECi,
	DI,
	DJNZ,
	EI,
	EX,
	EXaf,
	EXsp,
	EXX,
	HALT,
	IM,
	IN,
	INC,
	INC16,
	INCi,
	IND,
	INDR,
	INI,
	INIR,
	JP,
	JPC,
	JPNC,
	JR,
	JRC,
	JRNC,
	LD,
	LD16,
	LDi,
	LDi16,
	LDir,
	LDD,
	LDDR,
	LDI,
	LDIR,
	NEG,
	NOP,
	OR,
	OTDR,
	OTIR,
	OUT,
	OUTD,
	OUTI,
	POP,
	PUSH,
	RES,
	RESi,
	RET,
	RETC,
	RETNC,
	RETI,
	RETN,
	RL,
	RLA,
	RLC,
	RLCA,
	RLD,
	RR,
	RRA,
	RRC,
	RRCA,
	RRD,
	RST,
	SBC,
	SBC16,
	SCF,
	SET,
	SETi,
	SLA,
	SLL,
	SRA,
	SRL,
	SUB,
	XOR,

	OpCount,

	// dummy ops
	SHIFT = OpCount
}

static immutable Instruction[8] cbShift =
[
	Instruction.RLC,
	Instruction.RRC,
	Instruction.RL,
	Instruction.RR,
	Instruction.SLA,
	Instruction.SRA,
	Instruction.SLL,
	Instruction.SRL
];

// opcode tables...
static immutable Opcode[] sOpcodeTable =
[
	Opcode( Instruction.NOP,  4,  0,      0 ), // 0x00
	Opcode( Instruction.LD16, 10, Reg_BC, Imm_16 ),
	Opcode( Instruction.LDi,  7,  Out_BC, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_BC, 0 ),
	Opcode( Instruction.INC,  4,  Reg_B,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_B,  0 ),
	Opcode( Instruction.LD,   7,  Reg_B,  Imm_8 ),
	Opcode( Instruction.RLCA, 4,  0,      0 ),
	Opcode( Instruction.EXaf, 4,  Reg_AF, Reg_AF2 ),
	Opcode( Instruction.ADD16,11, Reg_HL, Reg_BC ),
	Opcode( Instruction.LD,   7,  Reg_A,  Ind_BC8 ),
	Opcode( Instruction.DEC16,6,  Reg_BC, 0 ),
	Opcode( Instruction.INC,  4,  Reg_C,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_C,  0 ),
	Opcode( Instruction.LD,   7,  Reg_C,  Imm_8 ),
	Opcode( Instruction.RRCA, 4,  0,      0 ),

	Opcode( Instruction.DJNZ, 8,  Rel_16, 0 ), // 0x10
	Opcode( Instruction.LD16, 10, Reg_DE, Imm_16 ),
	Opcode( Instruction.LDi,  7,  Out_DE, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_DE, 0 ),
	Opcode( Instruction.INC,  4,  Reg_D,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_D,  0 ),
	Opcode( Instruction.LD,   7,  Reg_D,  Imm_8 ),
	Opcode( Instruction.RLA,  4,  0,      0 ),
	Opcode( Instruction.JR,   12, Rel_16, 0 ),
	Opcode( Instruction.ADD16,11, Reg_HL, Reg_DE ),
	Opcode( Instruction.LD,   7,  Reg_A,  Ind_DE8 ),
	Opcode( Instruction.DEC16,6,  Reg_DE, 0 ),
	Opcode( Instruction.INC,  4,  Reg_E,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_E,  0 ),
	Opcode( Instruction.LD,   7,  Reg_E,  Imm_8 ),
	Opcode( Instruction.RRA,  4,  0,      0 ),

	Opcode( Instruction.JRNC, 7,  Cnd_Z,  Rel_16 ), // 0x20
	Opcode( Instruction.LD16, 10, Reg_HL, Imm_16 ),
	Opcode( Instruction.LDi16,20, Out_16, Reg_HL ),
	Opcode( Instruction.INC16,6,  Reg_HL, 0 ),
	Opcode( Instruction.INC,  4,  Reg_H,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_H,  0 ),
	Opcode( Instruction.LD,   7,  Reg_H,  Imm_8 ),
	Opcode( Instruction.DAA,  4,  0,      0 ),
	Opcode( Instruction.JRC,  7,  Cnd_Z,  Rel_16 ),
	Opcode( Instruction.ADD16,11, Reg_HL, Reg_HL ),
	Opcode( Instruction.LD16, 20, Reg_HL, Ind_16 ),
	Opcode( Instruction.DEC16,6,  Reg_HL, 0 ),
	Opcode( Instruction.INC,  4,  Reg_L,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_L,  0 ),
	Opcode( Instruction.LD,   7,  Reg_L,  Imm_8 ),
	Opcode( Instruction.CPL,  4,  0,      0 ),

	Opcode( Instruction.JRNC, 7,  Cnd_C,  Rel_16 ), // 0x30
	Opcode( Instruction.LD16, 10, Reg_SP, Imm_16 ),
	Opcode( Instruction.LDi,  13, Out_16, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_SP, 0 ),
	Opcode( Instruction.INCi, 7,  Ind_HL8,0 ),
	Opcode( Instruction.DECi, 7,  Ind_HL8,0 ),
	Opcode( Instruction.LDi,  10, Out_HL, Imm_8 ),
	Opcode( Instruction.SCF,  4,  0,      0 ),
	Opcode( Instruction.JRC,  7,  Cnd_C,  Rel_16 ),
	Opcode( Instruction.ADD16,11, Reg_HL, Reg_SP ),
	Opcode( Instruction.LD,   13, Reg_A,  Ind_8 ),
	Opcode( Instruction.DEC16,6,  Reg_SP, 0 ),
	Opcode( Instruction.INC,  4,  Reg_A,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_A,  0 ),
	Opcode( Instruction.LD,   7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.CCF,  4,  0,      0 ),

	Opcode( Instruction.LD,   4,  Reg_B,  Reg_B ), // 0x40
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_E ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_H ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_L ),
	Opcode( Instruction.LD,   7,  Reg_B,  Ind_HL8 ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_E ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_H ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_L ),
	Opcode( Instruction.LD,   7,  Reg_C,  Ind_HL8 ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_A ),

	Opcode( Instruction.LD,   4,  Reg_D,  Reg_B ), // 0x50
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_E ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_H ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_L ),
	Opcode( Instruction.LD,   7,  Reg_D,  Ind_HL8 ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_E ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_H ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_L ),
	Opcode( Instruction.LD,   7,  Reg_E,  Ind_HL8 ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_A ),

	Opcode( Instruction.LD,   4,  Reg_H,  Reg_B ), // 0x60
	Opcode( Instruction.LD,   4,  Reg_H,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_H,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_H,  Reg_E ),
	Opcode( Instruction.LD,   4,  Reg_H,  Reg_H ),
	Opcode( Instruction.LD,   4,  Reg_H,  Reg_L ),
	Opcode( Instruction.LD,   7,  Reg_H,  Ind_HL8 ),
	Opcode( Instruction.LD,   4,  Reg_H,  Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_L,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_L,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_L,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_L,  Reg_E ),
	Opcode( Instruction.LD,   4,  Reg_L,  Reg_H ),
	Opcode( Instruction.LD,   4,  Reg_L,  Reg_L ),
	Opcode( Instruction.LD,   7,  Reg_L,  Ind_HL8 ),
	Opcode( Instruction.LD,   4,  Reg_L,  Reg_A ),

	Opcode( Instruction.LDi,  7,  Out_HL, Reg_B ), // 0x70
	Opcode( Instruction.LDi,  7,  Out_HL, Reg_C ),
	Opcode( Instruction.LDi,  7,  Out_HL, Reg_D ),
	Opcode( Instruction.LDi,  7,  Out_HL, Reg_E ),
	Opcode( Instruction.LDi,  7,  Out_HL, Reg_H ),
	Opcode( Instruction.LDi,  7,  Out_HL, Reg_L ),
	Opcode( Instruction.HALT, 4,  0,      0 ),
	Opcode( Instruction.LDi,  7,  Out_HL, Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_E ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_H ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_L ),
	Opcode( Instruction.LD,   7,  Reg_A,  Ind_HL8 ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_A ),

	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_B ), // 0x80
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_H ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_L ),
	Opcode( Instruction.ADD,  7,  Reg_A,  Ind_HL8 ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_A ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_B ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_H ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_L ),
	Opcode( Instruction.ADC,  7,  Reg_A,  Ind_HL8 ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_A ),

	Opcode( Instruction.SUB,  4,  Reg_B,  0 ), // 0x90
	Opcode( Instruction.SUB,  4,  Reg_C,  0 ),
	Opcode( Instruction.SUB,  4,  Reg_D,  0 ),
	Opcode( Instruction.SUB,  4,  Reg_E,  0 ),
	Opcode( Instruction.SUB,  4,  Reg_H,  0 ),
	Opcode( Instruction.SUB,  4,  Reg_L,  0 ),
	Opcode( Instruction.SUB,  7,  Ind_HL8,0 ),
	Opcode( Instruction.SUB,  4,  Reg_A,  0 ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_B ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_H ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_L ),
	Opcode( Instruction.SBC,  7,  Reg_A,  Ind_HL8 ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_A ),

	Opcode( Instruction.AND,  4,  Reg_B,  0 ), // 0xA0
	Opcode( Instruction.AND,  4,  Reg_C,  0 ),
	Opcode( Instruction.AND,  4,  Reg_D,  0 ),
	Opcode( Instruction.AND,  4,  Reg_E,  0 ),
	Opcode( Instruction.AND,  4,  Reg_H,  0 ),
	Opcode( Instruction.AND,  4,  Reg_L,  0 ),
	Opcode( Instruction.AND,  7,  Ind_HL8,0 ),
	Opcode( Instruction.AND,  4,  Reg_A,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_B,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_C,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_D,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_E,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_H,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_L,  0 ),
	Opcode( Instruction.XOR,  7,  Ind_HL8,0 ),
	Opcode( Instruction.XOR,  4,  Reg_A,  0 ),

	Opcode( Instruction.OR,   4,  Reg_B,  0 ), // 0xB0
	Opcode( Instruction.OR,   4,  Reg_C,  0 ),
	Opcode( Instruction.OR,   4,  Reg_D,  0 ),
	Opcode( Instruction.OR,   4,  Reg_E,  0 ),
	Opcode( Instruction.OR,   4,  Reg_H,  0 ),
	Opcode( Instruction.OR,   4,  Reg_L,  0 ),
	Opcode( Instruction.OR,   7,  Ind_HL8,0 ),
	Opcode( Instruction.OR,   4,  Reg_A,  0 ),
	Opcode( Instruction.CP,   4,  Reg_B,  0 ),
	Opcode( Instruction.CP,   4,  Reg_C,  0 ),
	Opcode( Instruction.CP,   4,  Reg_D,  0 ),
	Opcode( Instruction.CP,   4,  Reg_E,  0 ),
	Opcode( Instruction.CP,   4,  Reg_H,  0 ),
	Opcode( Instruction.CP,   4,  Reg_L,  0 ),
	Opcode( Instruction.CP,   7,  Ind_HL8,0 ),
	Opcode( Instruction.CP,   4,  Reg_A,  0 ),

	Opcode( Instruction.RETNC,5,  Cnd_Z,  0 ), // 0xC0
	Opcode( Instruction.POP,  10, Reg_BC, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.JP,   10, Imm_16, 0 ),
	Opcode( Instruction.CALLNC,10,Cnd_Z,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_BC, 0 ),
	Opcode( Instruction.ADD,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 0,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_Z,  0 ),
	Opcode( Instruction.RET,  10, 0,      0 ),
	Opcode( Instruction.JPC,  10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.CALLC,10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.CALL, 17, Imm_16, 0 ),
	Opcode( Instruction.ADC,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 1,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_C,  0 ), // 0xD0
	Opcode( Instruction.POP,  10, Reg_DE, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.OUT,  11, Imm_8,  Reg_A ),
	Opcode( Instruction.CALLNC,10,Cnd_C,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_DE, 0 ),
	Opcode( Instruction.SUB,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 2,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_C,  0 ),
	Opcode( Instruction.EXX,  4,  0,      0 ),
	Opcode( Instruction.JPC,  10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.IN,   11, Reg_A,  Imm_8 ),
	Opcode( Instruction.CALLC,10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.SBC,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 3,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_PE, 0 ), // 0xE0
	Opcode( Instruction.POP,  10, Reg_HL, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.EXsp, 19, Ind_SP, Reg_HL ),
	Opcode( Instruction.CALLNC,10,Cnd_PE, Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_HL, 0 ),
	Opcode( Instruction.AND,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 4,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_PE, 0 ),
	Opcode( Instruction.JP,   4,  Out_HL, 0 ),
	Opcode( Instruction.JPC,  10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.EX,   4,  Reg_DE, Reg_HL ),
	Opcode( Instruction.CALLC,10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.XOR,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 5,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_M,  0 ), // 0xF0
	Opcode( Instruction.POP,  10, Reg_AF, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.DI,   4,  0,      0 ),
	Opcode( Instruction.CALLNC,10,Cnd_M,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_AF, 0 ),
	Opcode( Instruction.OR,   7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 6,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_M,  0 ),
	Opcode( Instruction.LD16, 6,  Reg_SP, Reg_HL ),
	Opcode( Instruction.JPC,  10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.EI,   4,  0,      0 ),
	Opcode( Instruction.CALLC,10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.CP,   7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 7,      0 )
];

static immutable Opcode[] opcodeTableCB =
[
	Opcode( Instruction.SHIFT,8,  Reg_B,  0 ),
	Opcode( Instruction.SHIFT,8,  Reg_C,  0 ),
	Opcode( Instruction.SHIFT,8,  Reg_D,  0 ),
	Opcode( Instruction.SHIFT,8,  Reg_E,  0 ),
	Opcode( Instruction.SHIFT,8,  Reg_H,  0 ),
	Opcode( Instruction.SHIFT,8,  Reg_L,  0 ),
	Opcode( Instruction.SHIFT,15, Ind_HL8,0 ),
	Opcode( Instruction.SHIFT,8,  Reg_A,  0 ),

	Opcode( Instruction.BIT,  8,  Reg_B,  0 ),
	Opcode( Instruction.BIT,  8,  Reg_C,  0 ),
	Opcode( Instruction.BIT,  8,  Reg_D,  0 ),
	Opcode( Instruction.BIT,  8,  Reg_E,  0 ),
	Opcode( Instruction.BIT,  8,  Reg_H,  0 ),
	Opcode( Instruction.BIT,  8,  Reg_L,  0 ),
	Opcode( Instruction.BIT,  12, Ind_HL8,0 ),
	Opcode( Instruction.BIT,  8,  Reg_A,  0 ),

	Opcode( Instruction.RES,  8,  Reg_B,  0 ),
	Opcode( Instruction.RES,  8,  Reg_C,  0 ),
	Opcode( Instruction.RES,  8,  Reg_D,  0 ),
	Opcode( Instruction.RES,  8,  Reg_E,  0 ),
	Opcode( Instruction.RES,  8,  Reg_H,  0 ),
	Opcode( Instruction.RES,  8,  Reg_L,  0 ),
	Opcode( Instruction.RESi, 15, Ind_HL8,0 ),
	Opcode( Instruction.RES,  8,  Reg_A,  0 ),

	Opcode( Instruction.SET,  8,  Reg_B,  0 ),
	Opcode( Instruction.SET,  8,  Reg_C,  0 ),
	Opcode( Instruction.SET,  8,  Reg_D,  0 ),
	Opcode( Instruction.SET,  8,  Reg_E,  0 ),
	Opcode( Instruction.SET,  8,  Reg_H,  0 ),
	Opcode( Instruction.SET,  8,  Reg_L,  0 ),
	Opcode( Instruction.SETi, 15, Ind_HL8,0 ),
	Opcode( Instruction.SET,  8,  Reg_A,  0 )
];

static immutable Opcode[] opcodeTableDD =
[
	Opcode( Instruction.NOP,  4,  0,      0 ), // 0x00
	Opcode( Instruction.LD16, 10, Reg_BC, Imm_16 ),
	Opcode( Instruction.LDi,  7,  Out_BC, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_BC, 0 ),
	Opcode( Instruction.INC,  4,  Reg_B,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_B,  0 ),
	Opcode( Instruction.LD,   7,  Reg_B,  Imm_8 ),
	Opcode( Instruction.RLCA, 4,  0,      0 ),
	Opcode( Instruction.EXaf, 4,  Reg_AF, Reg_AF2 ),
	Opcode( Instruction.ADD16,15, Reg_IX, Reg_BC ),
	Opcode( Instruction.LD,   7,  Reg_A,  Ind_BC8 ),
	Opcode( Instruction.DEC16,6,  Reg_BC, 0 ),
	Opcode( Instruction.INC,  4,  Reg_C,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_C,  0 ),
	Opcode( Instruction.LD,   7,  Reg_C,  Imm_8 ),
	Opcode( Instruction.RRCA, 4,  0,      0 ),

	Opcode( Instruction.DJNZ, 8,  Rel_16, 0 ), // 0x10
	Opcode( Instruction.LD16, 10, Reg_DE, Imm_16 ),
	Opcode( Instruction.LDi,  7,  Out_DE, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_DE, 0 ),
	Opcode( Instruction.INC,  4,  Reg_D,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_D,  0 ),
	Opcode( Instruction.LD,   7,  Reg_D,  Imm_8 ),
	Opcode( Instruction.RLA,  4,  0,      0 ),
	Opcode( Instruction.JR,   12, Rel_16, 0 ),
	Opcode( Instruction.ADD16,15, Reg_IX, Reg_DE ),
	Opcode( Instruction.LD,   7,  Reg_A,  Ind_DE8 ),
	Opcode( Instruction.DEC16,6,  Reg_DE, 0 ),
	Opcode( Instruction.INC,  4,  Reg_E,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_E,  0 ),
	Opcode( Instruction.LD,   7,  Reg_E,  Imm_8 ),
	Opcode( Instruction.RRA,  4,  0,      0 ),

	Opcode( Instruction.JRNC, 7,  Cnd_Z,  Rel_16 ), // 0x20
	Opcode( Instruction.LD16, 14, Reg_IX, Imm_16 ),
	Opcode( Instruction.LDi16,20, Out_16, Reg_IX ),
	Opcode( Instruction.INC16,10, Reg_IX, 0 ),
	Opcode( Instruction.INC,  9,  Reg_IXH,0 ),
	Opcode( Instruction.DEC,  9,  Reg_IXH,0 ),
	Opcode( Instruction.LD,   9,  Reg_IXH,Imm_8 ), // *** CORRECT CYCLE COUNT??
	Opcode( Instruction.DAA,  4,  0,      0 ),
	Opcode( Instruction.JRC,  7,  Cnd_Z,  Rel_16 ),
	Opcode( Instruction.ADD16,15, Reg_IX, Reg_IX ),
	Opcode( Instruction.LD16, 20, Reg_IX, Ind_16 ),
	Opcode( Instruction.DEC16,10, Reg_IX, 0 ),
	Opcode( Instruction.INC,  9,  Reg_IXL,0 ),
	Opcode( Instruction.DEC,  9,  Reg_IXL,0 ),
	Opcode( Instruction.LD,   9,  Reg_IXL,Imm_8 ), // *** CORRECT CYCLE COUNT??
	Opcode( Instruction.CPL,  4,  0,      0 ),

	Opcode( Instruction.JRNC, 7,  Cnd_C,  Rel_16 ), // 0x30
	Opcode( Instruction.LD16, 10, Reg_SP, Imm_16 ),
	Opcode( Instruction.LDi,  13, Out_16, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_SP, 0 ),
	Opcode( Instruction.INCi, 23, Idx_IX8,0 ),
	Opcode( Instruction.DECi, 23, Idx_IX8,0 ),
	Opcode( Instruction.LDi,  19, Odx_IX,Imm_8 ),
	Opcode( Instruction.SCF,  4,  0,      0 ),
	Opcode( Instruction.JRC,  7,  Cnd_C,  Rel_16 ),
	Opcode( Instruction.ADD16,15, Reg_IX, Reg_SP ),
	Opcode( Instruction.LD,   13, Reg_A,  Ind_8 ),
	Opcode( Instruction.DEC16,6,  Reg_SP, 0 ),
	Opcode( Instruction.INC,  4,  Reg_A,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_A,  0 ),
	Opcode( Instruction.LD,   7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.CCF,  4,  0,      0 ),

	Opcode( Instruction.LD,   4,  Reg_B,  Reg_B ), // 0x40
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_B,  Reg_IXH ),
	Opcode( Instruction.LD,   9,  Reg_B,  Reg_IXL ),
	Opcode( Instruction.LD,   19, Reg_B,  Idx_IX8 ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_C,  Reg_IXH ),
	Opcode( Instruction.LD,   9,  Reg_C,  Reg_IXL ),
	Opcode( Instruction.LD,   19, Reg_C,  Idx_IX8 ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_A ),

	Opcode( Instruction.LD,   4,  Reg_D,  Reg_B ), // 0x50
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_D,  Reg_IXH ),
	Opcode( Instruction.LD,   9,  Reg_D,  Reg_IXL ),
	Opcode( Instruction.LD,   19, Reg_D,  Idx_IX8 ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_E,  Reg_IXH ),
	Opcode( Instruction.LD,   9,  Reg_E,  Reg_IXL ),
	Opcode( Instruction.LD,   19, Reg_E,  Idx_IX8 ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_A ),

	Opcode( Instruction.LD,   9,  Reg_IXH,Reg_B ), // 0x60
	Opcode( Instruction.LD,   9,  Reg_IXH,Reg_C ),
	Opcode( Instruction.LD,   9,  Reg_IXH,Reg_D ),
	Opcode( Instruction.LD,   9,  Reg_IXH,Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_IXH,Reg_IXH ),
	Opcode( Instruction.LD,   9,  Reg_IXH,Reg_IXL ),
	Opcode( Instruction.LD,   19, Reg_H,  Idx_IX8 ), // ***!!! SURELY THIS SHOULD BE IXH,IX not H,IX ???***
	Opcode( Instruction.LD,   9,  Reg_IXH,Reg_A ),
	Opcode( Instruction.LD,   9,  Reg_IXL,Reg_B ),
	Opcode( Instruction.LD,   9,  Reg_IXL,Reg_C ),
	Opcode( Instruction.LD,   9,  Reg_IXL,Reg_D ),
	Opcode( Instruction.LD,   9,  Reg_IXL,Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_IXL,Reg_IXH ),
	Opcode( Instruction.LD,   9,  Reg_IXL,Reg_IXL ),
	Opcode( Instruction.LD,   19, Reg_L,  Idx_IX8 ), // ***!!! SURELY THIS SHOULD BE IXL,IX not L,IX ???***
	Opcode( Instruction.LD,   9,  Reg_IXL,Reg_A ),

	Opcode( Instruction.LDi,  19, Odx_IX ,Reg_B ), // 0x70
	Opcode( Instruction.LDi,  19, Odx_IX ,Reg_C ),
	Opcode( Instruction.LDi,  19, Odx_IX ,Reg_D ),
	Opcode( Instruction.LDi,  19, Odx_IX ,Reg_E ),
	Opcode( Instruction.LDi,  19, Odx_IX ,Reg_H ), // *** SHOULD THESE REFERENCE IXL??
	Opcode( Instruction.LDi,  19, Odx_IX ,Reg_L ), // *** SHOULD THESE REFERENCE IXL??
	Opcode( Instruction.HALT, 4,  0,      0 ),
	Opcode( Instruction.LDi,  19, Odx_IX ,Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_A,  Reg_IXH ),
	Opcode( Instruction.LD,   9,  Reg_A,  Reg_IXL ),
	Opcode( Instruction.LD,   19, Reg_A,  Idx_IX8 ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_A ),

	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_B ), // 0x80
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.ADD,  9,  Reg_A,  Reg_IXH ),
	Opcode( Instruction.ADD,  9,  Reg_A,  Reg_IXL ),
	Opcode( Instruction.ADD,  19, Reg_A,  Idx_IX8 ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_A ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_B ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.ADC,  9,  Reg_A,  Reg_IXH ),
	Opcode( Instruction.ADC,  9,  Reg_A,  Reg_IXL ),
	Opcode( Instruction.ADC,  19, Reg_A,  Idx_IX8 ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_A ),

	Opcode( Instruction.SUB,  4,  Reg_B,  0 ), // 0x90
	Opcode( Instruction.SUB,  4,  Reg_C,  0 ),
	Opcode( Instruction.SUB,  4,  Reg_D,  0 ),
	Opcode( Instruction.SUB,  4,  Reg_E,  0 ),
	Opcode( Instruction.SUB,  9,  Reg_IXH,0 ),
	Opcode( Instruction.SUB,  9,  Reg_IXL,0 ),
	Opcode( Instruction.SUB,  19, Idx_IX8,0 ),
	Opcode( Instruction.SUB,  4,  Reg_A,  0 ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_B ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.SBC,  9,  Reg_A,  Reg_IXH ),
	Opcode( Instruction.SBC,  9,  Reg_A,  Reg_IXL ),
	Opcode( Instruction.SBC,  19, Reg_A,  Idx_IX8 ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_A ),

	Opcode( Instruction.AND,  4,  Reg_B,  0 ), // 0xA0
	Opcode( Instruction.AND,  4,  Reg_C,  0 ),
	Opcode( Instruction.AND,  4,  Reg_D,  0 ),
	Opcode( Instruction.AND,  4,  Reg_E,  0 ),
	Opcode( Instruction.AND,  9,  Reg_IXH,0 ),
	Opcode( Instruction.AND,  9,  Reg_IXL,0 ),
	Opcode( Instruction.AND,  19, Idx_IX8,0 ),
	Opcode( Instruction.AND,  4,  Reg_A,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_B,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_C,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_D,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_E,  0 ),
	Opcode( Instruction.XOR,  9,  Reg_IXH,0 ),
	Opcode( Instruction.XOR,  9,  Reg_IXL,0 ),
	Opcode( Instruction.XOR,  19, Idx_IX8,0 ),
	Opcode( Instruction.XOR,  4,  Reg_A,  0 ),

	Opcode( Instruction.OR,   4,  Reg_B,  0 ), // 0xB0
	Opcode( Instruction.OR,   4,  Reg_C,  0 ),
	Opcode( Instruction.OR,   4,  Reg_D,  0 ),
	Opcode( Instruction.OR,   4,  Reg_E,  0 ),
	Opcode( Instruction.OR,   9,  Reg_IXH,0 ),
	Opcode( Instruction.OR,   9,  Reg_IXL,0 ),
	Opcode( Instruction.OR,   19, Idx_IX8,0 ),
	Opcode( Instruction.OR,   4,  Reg_A,  0 ),
	Opcode( Instruction.CP,   4,  Reg_B,  0 ),
	Opcode( Instruction.CP,   4,  Reg_C,  0 ),
	Opcode( Instruction.CP,   4,  Reg_D,  0 ),
	Opcode( Instruction.CP,   4,  Reg_E,  0 ),
	Opcode( Instruction.CP,   9,  Reg_IXH,0 ),
	Opcode( Instruction.CP,   9,  Reg_IXL,0 ),
	Opcode( Instruction.CP,   19, Idx_IX8,0 ),
	Opcode( Instruction.CP,   4,  Reg_A,  0 ),

	Opcode( Instruction.RETNC,5,  Cnd_Z,  0 ), // 0xC0
	Opcode( Instruction.POP,  10, Reg_BC, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.JP,   10, Imm_16, 0 ),
	Opcode( Instruction.CALLNC,10,Cnd_Z,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_BC, 0 ),
	Opcode( Instruction.ADD,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 0,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_Z,  0 ),
	Opcode( Instruction.RET,  10, 0,      0 ),
	Opcode( Instruction.JPC,  10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  Idx_IX, 0 ),
	Opcode( Instruction.CALLC,10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.CALL, 17, Imm_16, 0 ),
	Opcode( Instruction.ADC,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 1,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_C,  0 ), // 0xD0
	Opcode( Instruction.POP,  10, Reg_DE, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.OUT,  11, Imm_8,  Reg_A ),
	Opcode( Instruction.CALLNC,10,Cnd_C,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_DE, 0 ),
	Opcode( Instruction.SUB,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 2,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_C,  0 ),
	Opcode( Instruction.EXX,  4,  0,      0 ),
	Opcode( Instruction.JPC,  10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.IN,   11, Reg_A,  Imm_8 ),
	Opcode( Instruction.CALLC,10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.SBC,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 3,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_PE, 0 ), // 0xE0
	Opcode( Instruction.POP,  14, Reg_IX, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.EXsp, 23, Ind_SP, Reg_IX ),
	Opcode( Instruction.CALLNC,10,Cnd_PE, Imm_16 ),
	Opcode( Instruction.PUSH, 15, Reg_IX, 0 ),
	Opcode( Instruction.AND,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 4,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_PE, 0 ),
	Opcode( Instruction.JP,   8,  Out_IX, 0 ),
	Opcode( Instruction.JPC,  10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.EX,   4,  Reg_DE, Reg_HL ), // ***!!! SURELY THIS SHOULD BE DE,IX not DE,HL ???***
	Opcode( Instruction.CALLC,10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.XOR,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 5,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_M,  0 ), // 0xF0
	Opcode( Instruction.POP,  10, Reg_AF, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.DI,   4,  0,      0 ),
	Opcode( Instruction.CALLNC,10,Cnd_M,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_AF, 0 ),
	Opcode( Instruction.OR,   7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 6,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_M,  0 ),
	Opcode( Instruction.LD16, 10, Reg_SP, Reg_IX ),
	Opcode( Instruction.JPC,  10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.EI,   4,  0,      0 ),
	Opcode( Instruction.CALLC,10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.CP,   7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 7,      0 )
];

static immutable Opcode[] opcodeTableED =
[
	Opcode( Instruction.IN,   12, Reg_B,  Reg_BC ), // 0x40
	Opcode( Instruction.OUT,  12, Reg_BC,  Reg_B ),
	Opcode( Instruction.SBC16,15, Reg_HL, Reg_BC ),
	Opcode( Instruction.LDi16,20, Out_16, Reg_BC ),
	Opcode( Instruction.NEG,  8,  0,      0 ),
	Opcode( Instruction.RETN, 14, 0,      0 ),
	Opcode( Instruction.IM,   8,  0,      0 ),
	Opcode( Instruction.LD,   9,  Reg_I,  Reg_A ),
	Opcode( Instruction.IN,   12, Reg_C,  Reg_BC ),
	Opcode( Instruction.OUT,  12, Reg_BC,  Reg_C ),
	Opcode( Instruction.ADC16,15, Reg_HL, Reg_BC ),
	Opcode( Instruction.LD16, 20, Reg_BC, Ind_16 ),
	Opcode( Instruction.NEG,  8,  0,      0 ),
	Opcode( Instruction.RETI, 14, 0,      0 ),
	Opcode( Instruction.IM,   8,  0,      0 ),
	Opcode( Instruction.LD,   9,  Reg_R,  Reg_A ),

	Opcode( Instruction.IN,   12, Reg_D,  Reg_BC ), // 0x50
	Opcode( Instruction.OUT,  12, Reg_BC,  Reg_D ),
	Opcode( Instruction.SBC16,15, Reg_HL, Reg_DE ),
	Opcode( Instruction.LDi16,20, Out_16, Reg_DE ),
	Opcode( Instruction.NEG,  8,  0,      0 ),
	Opcode( Instruction.RETN, 14, 0,      0 ),
	Opcode( Instruction.IM,   8,  1,      0 ),
	Opcode( Instruction.LDir, 9,  Reg_A,  Reg_I ),
	Opcode( Instruction.IN,   12, Reg_E,  Reg_BC ),
	Opcode( Instruction.OUT,  12, Reg_BC,  Reg_E ),
	Opcode( Instruction.ADC16,15, Reg_HL, Reg_DE ),
	Opcode( Instruction.LD16, 20, Reg_DE, Ind_16 ),
	Opcode( Instruction.NEG,  8,  0,      0 ),
	Opcode( Instruction.RETI, 14, 0,      0 ),
	Opcode( Instruction.IM,   8,  2,      0 ),
	Opcode( Instruction.LDir, 9,  Reg_A,  Reg_R ),

	Opcode( Instruction.IN,   12, Reg_H,  Reg_BC ), // 0x60
	Opcode( Instruction.OUT,  12, Reg_BC,  Reg_H ),
	Opcode( Instruction.SBC16,15, Reg_HL, Reg_HL ),
	Opcode( Instruction.LDi16,20, Out_16, Reg_HL ),
	Opcode( Instruction.NEG,  8,  0,      0 ),
	Opcode( Instruction.RETN, 14, 0,      0 ),
	Opcode( Instruction.IM,   8,  0,      0 ),
	Opcode( Instruction.RRD,  18, 0,      0 ),
	Opcode( Instruction.IN,   12, Reg_L,  Reg_BC ),
	Opcode( Instruction.OUT,  12, Reg_BC,  Reg_L ),
	Opcode( Instruction.ADC16,15, Reg_HL, Reg_HL ),
	Opcode( Instruction.LD16, 20, Reg_HL, Ind_16 ),
	Opcode( Instruction.NEG,  8,  0,      0 ),
	Opcode( Instruction.RETI, 14, 0,      0 ),
	Opcode( Instruction.IM,   8,  0,      0 ),
	Opcode( Instruction.RLD,  18, 0,      0 ),

	Opcode( Instruction.IN,   12, Reg_C,  0 ), // 0x70
	Opcode( Instruction.OUT,  12, Reg_BC,  0 ),
	Opcode( Instruction.SBC16,15, Reg_HL, Reg_SP ),
	Opcode( Instruction.LDi16,20, Out_16, Reg_SP ),
	Opcode( Instruction.NEG,  8,  0,      0 ),
	Opcode( Instruction.RETN, 14, 0,      0 ),
	Opcode( Instruction.IM,   8,  1,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.IN,   12, Reg_A,  Reg_BC ),
	Opcode( Instruction.OUT,  12, Reg_BC,  Reg_A ),
	Opcode( Instruction.ADC16,15, Reg_HL, Reg_SP ),
	Opcode( Instruction.LD16, 20, Reg_SP, Ind_16 ),
	Opcode( Instruction.NEG,  8,  0,      0 ),
	Opcode( Instruction.RETI, 14, 0,      0 ),
	Opcode( Instruction.IM,   8,  2,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),

	Opcode( Instruction.UNK,  0,  0,      0 ), // 0x80
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),

	Opcode( Instruction.UNK,  0,  0,      0 ), // 0x90
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),

	Opcode( Instruction.LDI,  16, 0,      0 ), // 0xA0
	Opcode( Instruction.CPI,  16, 0,      0 ),
	Opcode( Instruction.INI,  16, 0,      0 ),
	Opcode( Instruction.OUTI, 16, 0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.LDD,  16, 0,      0 ),
	Opcode( Instruction.CPD,  16, 0,      0 ),
	Opcode( Instruction.IND,  16, 0,      0 ),
	Opcode( Instruction.OUTD, 16, 0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),

	Opcode( Instruction.LDIR, 16, 0,      0 ), // 0xB0
	Opcode( Instruction.CPIR, 16, 0,      0 ),
	Opcode( Instruction.INIR, 16, 0,      0 ),
	Opcode( Instruction.OTIR, 16, 0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.LDDR, 16, 0,      0 ),
	Opcode( Instruction.CPDR, 16, 0,      0 ),
	Opcode( Instruction.INDR, 16, 0,      0 ),
	Opcode( Instruction.OTDR, 16, 0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.UNK,  0,  0,      0 )
];

static immutable Opcode[] opcodeTableFD =
[
	Opcode( Instruction.NOP,  4,  0,      0 ), // 0x00
	Opcode( Instruction.LD16, 10, Reg_BC, Imm_16 ),
	Opcode( Instruction.LDi,  7,  Out_BC, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_BC, 0 ),
	Opcode( Instruction.INC,  4,  Reg_B,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_B,  0 ),
	Opcode( Instruction.LD,   7,  Reg_B,  Imm_8 ),
	Opcode( Instruction.RLCA, 4,  0,      0 ),
	Opcode( Instruction.EXaf, 4,  Reg_AF, Reg_AF2 ),
	Opcode( Instruction.ADD16,15, Reg_IY, Reg_BC ),
	Opcode( Instruction.LD,   7,  Reg_A,  Ind_BC8 ),
	Opcode( Instruction.DEC16,6,  Reg_BC, 0 ),
	Opcode( Instruction.INC,  4,  Reg_C,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_C,  0 ),
	Opcode( Instruction.LD,   7,  Reg_C,  Imm_8 ),
	Opcode( Instruction.RRCA, 4,  0,      0 ),

	Opcode( Instruction.DJNZ, 8,  Rel_16, 0 ), // 0x10
	Opcode( Instruction.LD16, 10, Reg_DE, Imm_16 ),
	Opcode( Instruction.LDi,  7,  Out_DE, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_DE, 0 ),
	Opcode( Instruction.INC,  4,  Reg_D,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_D,  0 ),
	Opcode( Instruction.LD,   7,  Reg_D,  Imm_8 ),
	Opcode( Instruction.RLA,  4,  0,      0 ),
	Opcode( Instruction.JR,   12, Rel_16, 0 ),
	Opcode( Instruction.ADD16,15, Reg_IY, Reg_DE ),
	Opcode( Instruction.LD,   7,  Reg_A,  Ind_DE8 ),
	Opcode( Instruction.DEC16,6,  Reg_DE, 0 ),
	Opcode( Instruction.INC,  4,  Reg_E,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_E,  0 ),
	Opcode( Instruction.LD,   7,  Reg_E,  Imm_8 ),
	Opcode( Instruction.RRA,  4,  0,      0 ),

	Opcode( Instruction.JRNC, 7,  Cnd_Z,  Rel_16 ), // 0x20
	Opcode( Instruction.LD16, 14, Reg_IY, Imm_16 ),
	Opcode( Instruction.LDi16,20, Out_16, Reg_IY ),
	Opcode( Instruction.INC16,10, Reg_IY, 0 ),
	Opcode( Instruction.INC,  9,  Reg_IYH,0 ),
	Opcode( Instruction.DEC,  9,  Reg_IYH,0 ),
	Opcode( Instruction.LD,   9,  Reg_IYH,Imm_8 ), // *** CORRECT CYCLE COUNT??
	Opcode( Instruction.DAA,  4,  0,      0 ),
	Opcode( Instruction.JRC,  7,  Cnd_Z,  Rel_16 ),
	Opcode( Instruction.ADD16,15, Reg_IY, Reg_IY ),
	Opcode( Instruction.LD16, 20, Reg_IY, Ind_16 ),
	Opcode( Instruction.DEC16,10, Reg_IY, 0 ),
	Opcode( Instruction.INC,  9,  Reg_IYL,0 ),
	Opcode( Instruction.DEC,  9,  Reg_IYL,0 ),
	Opcode( Instruction.LD,   9,  Reg_IYL,Imm_8 ), // *** CORRECT CYCLE COUNT??
	Opcode( Instruction.CPL,  4,  0,      0 ),

	Opcode( Instruction.JRNC, 7,  Cnd_C,  Rel_16 ), // 0x30
	Opcode( Instruction.LD16, 10, Reg_SP, Imm_16 ),
	Opcode( Instruction.LDi,  13, Out_16, Reg_A ),
	Opcode( Instruction.INC16,6,  Reg_SP, 0 ),
	Opcode( Instruction.INCi, 23, Idx_IY8,0 ),
	Opcode( Instruction.DECi, 23, Idx_IY8,0 ),
	Opcode( Instruction.LDi,  19, Odx_IY ,Imm_8 ),
	Opcode( Instruction.SCF,  4,  0,      0 ),
	Opcode( Instruction.JRC,  7,  Cnd_C,  Rel_16 ),
	Opcode( Instruction.ADD16,15, Reg_IY, Reg_SP ),
	Opcode( Instruction.LD,   13, Reg_A,  Ind_8 ),
	Opcode( Instruction.DEC16,6,  Reg_SP, 0 ),
	Opcode( Instruction.INC,  4,  Reg_A,  0 ),
	Opcode( Instruction.DEC,  4,  Reg_A,  0 ),
	Opcode( Instruction.LD,   7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.CCF,  4,  0,      0 ),

	Opcode( Instruction.LD,   4,  Reg_B,  Reg_B ), // 0x40
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_B,  Reg_IYH ),
	Opcode( Instruction.LD,   9,  Reg_B,  Reg_IYL ),
	Opcode( Instruction.LD,   19, Reg_B,  Idx_IY8 ),
	Opcode( Instruction.LD,   4,  Reg_B,  Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_C,  Reg_IYH ),
	Opcode( Instruction.LD,   9,  Reg_C,  Reg_IYL ),
	Opcode( Instruction.LD,   19, Reg_C,  Idx_IY8 ),
	Opcode( Instruction.LD,   4,  Reg_C,  Reg_A ),

	Opcode( Instruction.LD,   4,  Reg_D,  Reg_B ), // 0x50
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_D,  Reg_IYH ),
	Opcode( Instruction.LD,   9,  Reg_D,  Reg_IYL ),
	Opcode( Instruction.LD,   19, Reg_D,  Idx_IY8 ),
	Opcode( Instruction.LD,   4,  Reg_D,  Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_E,  Reg_IYH ),
	Opcode( Instruction.LD,   9,  Reg_E,  Reg_IYL ),
	Opcode( Instruction.LD,   19, Reg_E,  Idx_IY8 ),
	Opcode( Instruction.LD,   4,  Reg_E,  Reg_A ),

	Opcode( Instruction.LD,   9,  Reg_IYH,Reg_B ), // 0x60
	Opcode( Instruction.LD,   9,  Reg_IYH,Reg_C ),
	Opcode( Instruction.LD,   9,  Reg_IYH,Reg_D ),
	Opcode( Instruction.LD,   9,  Reg_IYH,Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_IYH,Reg_IYH ),
	Opcode( Instruction.LD,   9,  Reg_IYH,Reg_IYL ),
	Opcode( Instruction.LD,   19, Reg_H,  Idx_IY8 ), // ***!!! SURELY THIS SHOULD BE IYH,IY not H,IY ???***
	Opcode( Instruction.LD,   9,  Reg_IYH,Reg_A ),
	Opcode( Instruction.LD,   9,  Reg_IYL,Reg_B ),
	Opcode( Instruction.LD,   9,  Reg_IYL,Reg_C ),
	Opcode( Instruction.LD,   9,  Reg_IYL,Reg_D ),
	Opcode( Instruction.LD,   9,  Reg_IYL,Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_IYL,Reg_IYH ),
	Opcode( Instruction.LD,   9,  Reg_IYL,Reg_IYL ),
	Opcode( Instruction.LD,   19, Reg_L,  Idx_IY8 ), // ***!!! SURELY THIS SHOULD BE IYL,IY not L,IY ???***
	Opcode( Instruction.LD,   9,  Reg_IYL,Reg_A ),

	Opcode( Instruction.LDi,  19, Odx_IY ,Reg_B ), // 0x70
	Opcode( Instruction.LDi,  19, Odx_IY ,Reg_C ),
	Opcode( Instruction.LDi,  19, Odx_IY ,Reg_D ),
	Opcode( Instruction.LDi,  19, Odx_IY ,Reg_E ),
	Opcode( Instruction.LDi,  19, Odx_IY ,Reg_H ), // *** SHOULD THESE REFERENCE IYL??
	Opcode( Instruction.LDi,  19, Odx_IY ,Reg_L ), // *** SHOULD THESE REFERENCE IYL??
	Opcode( Instruction.HALT, 4,  0,      0 ),
	Opcode( Instruction.LDi,  19, Odx_IY ,Reg_A ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_B ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_C ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_D ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_E ),
	Opcode( Instruction.LD,   9,  Reg_A,  Reg_IYH ),
	Opcode( Instruction.LD,   9,  Reg_A,  Reg_IYL ),
	Opcode( Instruction.LD,   19, Reg_A,  Idx_IY8 ),
	Opcode( Instruction.LD,   4,  Reg_A,  Reg_A ),

	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_B ), // 0x80
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.ADD,  9,  Reg_A,  Reg_IYH ),
	Opcode( Instruction.ADD,  9,  Reg_A,  Reg_IYL ),
	Opcode( Instruction.ADD,  19, Reg_A,  Idx_IY8 ),
	Opcode( Instruction.ADD,  4,  Reg_A,  Reg_A ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_B ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.ADC,  9,  Reg_A,  Reg_IYH ),
	Opcode( Instruction.ADC,  9,  Reg_A,  Reg_IYL ),
	Opcode( Instruction.ADC,  19, Reg_A,  Idx_IY8 ),
	Opcode( Instruction.ADC,  4,  Reg_A,  Reg_A ),

	Opcode( Instruction.SUB,  4,  Reg_B,  0 ), // 0x90
	Opcode( Instruction.SUB,  4,  Reg_C,  0 ),
	Opcode( Instruction.SUB,  4,  Reg_D,  0 ),
	Opcode( Instruction.SUB,  4,  Reg_E,  0 ),
	Opcode( Instruction.SUB,  9,  Reg_IYH,0 ),
	Opcode( Instruction.SUB,  9,  Reg_IYL,0 ),
	Opcode( Instruction.SUB,  19, Idx_IY8,0 ),
	Opcode( Instruction.SUB,  4,  Reg_A,  0 ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_B ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_C ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_D ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_E ),
	Opcode( Instruction.SBC,  9,  Reg_A,  Reg_IYH ),
	Opcode( Instruction.SBC,  9,  Reg_A,  Reg_IYL ),
	Opcode( Instruction.SBC,  19, Reg_A,  Idx_IY8 ),
	Opcode( Instruction.SBC,  4,  Reg_A,  Reg_A ),

	Opcode( Instruction.AND,  4,  Reg_B,  0 ), // 0xA0
	Opcode( Instruction.AND,  4,  Reg_C,  0 ),
	Opcode( Instruction.AND,  4,  Reg_D,  0 ),
	Opcode( Instruction.AND,  4,  Reg_E,  0 ),
	Opcode( Instruction.AND,  9,  Reg_IYH,0 ),
	Opcode( Instruction.AND,  9,  Reg_IYL,0 ),
	Opcode( Instruction.AND,  19, Idx_IY8,0 ),
	Opcode( Instruction.AND,  4,  Reg_A,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_B,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_C,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_D,  0 ),
	Opcode( Instruction.XOR,  4,  Reg_E,  0 ),
	Opcode( Instruction.XOR,  9,  Reg_IYH,0 ),
	Opcode( Instruction.XOR,  9,  Reg_IYL,0 ),
	Opcode( Instruction.XOR,  19, Idx_IY8,0 ),
	Opcode( Instruction.XOR,  4,  Reg_A,  0 ),

	Opcode( Instruction.OR,   4,  Reg_B,  0 ), // 0xB0
	Opcode( Instruction.OR,   4,  Reg_C,  0 ),
	Opcode( Instruction.OR,   4,  Reg_D,  0 ),
	Opcode( Instruction.OR,   4,  Reg_E,  0 ),
	Opcode( Instruction.OR,   9,  Reg_IYH,0 ),
	Opcode( Instruction.OR,   9,  Reg_IYL,0 ),
	Opcode( Instruction.OR,   19, Idx_IY8,0 ),
	Opcode( Instruction.OR,   4,  Reg_A,  0 ),
	Opcode( Instruction.CP,   4,  Reg_B,  0 ),
	Opcode( Instruction.CP,   4,  Reg_C,  0 ),
	Opcode( Instruction.CP,   4,  Reg_D,  0 ),
	Opcode( Instruction.CP,   4,  Reg_E,  0 ),
	Opcode( Instruction.CP,   9,  Reg_IYH,0 ),
	Opcode( Instruction.CP,   9,  Reg_IYL,0 ),
	Opcode( Instruction.CP,   19, Idx_IY8,0 ),
	Opcode( Instruction.CP,   4,  Reg_A,  0 ),

	Opcode( Instruction.RETNC,5,  Cnd_Z,  0 ), // 0xC0
	Opcode( Instruction.POP,  10, Reg_BC, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.JP,   10, Imm_16, 0 ),
	Opcode( Instruction.CALLNC,10,Cnd_Z,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_BC, 0 ),
	Opcode( Instruction.ADD,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 0,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_Z,  0 ),
	Opcode( Instruction.RET,  10, 0,      0 ),
	Opcode( Instruction.JPC,  10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  Idx_IY, 0 ),
	Opcode( Instruction.CALLC,10, Cnd_Z,  Imm_16 ),
	Opcode( Instruction.CALL, 17, Imm_16, 0 ),
	Opcode( Instruction.ADC,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 1,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_C,  0 ), // 0xD0
	Opcode( Instruction.POP,  10, Reg_DE, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.OUT,  11, Imm_8,  Reg_A ),
	Opcode( Instruction.CALLNC,10,Cnd_C,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_DE, 0 ),
	Opcode( Instruction.SUB,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 2,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_C,  0 ),
	Opcode( Instruction.EXX,  4,  0,      0 ),
	Opcode( Instruction.JPC,  10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.IN,   11, Reg_A,  Imm_8 ),
	Opcode( Instruction.CALLC,10, Cnd_C,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.SBC,  7,  Reg_A,  Imm_8 ),
	Opcode( Instruction.RST,  11, 3,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_PE, 0 ), // 0xE0
	Opcode( Instruction.POP,  14, Reg_IY, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.EXsp, 23, Ind_SP, Reg_IY ),
	Opcode( Instruction.CALLNC,10,Cnd_PE, Imm_16 ),
	Opcode( Instruction.PUSH, 15, Reg_IY, 0 ),
	Opcode( Instruction.AND,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 4,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_PE, 0 ),
	Opcode( Instruction.JP,   8,  Out_IY, 0 ),
	Opcode( Instruction.JPC,  10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.EX,   4,  Reg_DE, Reg_HL ), // ***!!! SURELY THIS SHOULD BE DE,IY not DE,HL ???***
	Opcode( Instruction.CALLC,10, Cnd_PE, Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.XOR,  7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 5,      0 ),

	Opcode( Instruction.RETNC,5,  Cnd_M,  0 ), // 0xF0
	Opcode( Instruction.POP,  10, Reg_AF, 0 ),
	Opcode( Instruction.JPNC, 10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.DI,   4,  0,      0 ),
	Opcode( Instruction.CALLNC,10,Cnd_M,  Imm_16 ),
	Opcode( Instruction.PUSH, 11, Reg_AF, 0 ),
	Opcode( Instruction.OR,   7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 6,      0 ),
	Opcode( Instruction.RETC, 5,  Cnd_M,  0 ),
	Opcode( Instruction.LD16, 10, Reg_SP, Reg_IY ),
	Opcode( Instruction.JPC,  10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.EI,   4,  0,      0 ),
	Opcode( Instruction.CALLC,10, Cnd_M,  Imm_16 ),
	Opcode( Instruction.UNK,  0,  0,      0 ),
	Opcode( Instruction.CP,   7,  Imm_8,  0 ),
	Opcode( Instruction.RST,  11, 7,      0 )
];

static immutable Opcode[] opcodeTableXXCB =
[
	Opcode( Instruction.SHIFT,23, 0,      Reg_B ),
	Opcode( Instruction.SHIFT,23, 0,      Reg_C ),
	Opcode( Instruction.SHIFT,23, 0,      Reg_D ),
	Opcode( Instruction.SHIFT,23, 0,      Reg_E ),
	Opcode( Instruction.SHIFT,23, 0,      Reg_H ),
	Opcode( Instruction.SHIFT,23, 0,      Reg_L ),
	Opcode( Instruction.SHIFT,23, 0,      0 ),
	Opcode( Instruction.SHIFT,23, 0,      Reg_A ),

	Opcode( Instruction.BIT,  20, 0,      0 ),
	Opcode( Instruction.BIT,  20, 0,      0 ),
	Opcode( Instruction.BIT,  20, 0,      0 ),
	Opcode( Instruction.BIT,  20, 0,      0 ),
	Opcode( Instruction.BIT,  20, 0,      0 ),
	Opcode( Instruction.BIT,  20, 0,      0 ),
	Opcode( Instruction.BIT,  20, 0,      0 ),
	Opcode( Instruction.BIT,  20, 0,      0 ),

	Opcode( Instruction.RESi, 23, 0,      Reg_B ),
	Opcode( Instruction.RESi, 23, 0,      Reg_C ),
	Opcode( Instruction.RESi, 23, 0,      Reg_D ),
	Opcode( Instruction.RESi, 23, 0,      Reg_E ),
	Opcode( Instruction.RESi, 23, 0,      Reg_H ),
	Opcode( Instruction.RESi, 23, 0,      Reg_L ),
	Opcode( Instruction.RESi, 23, 0,      0 ),
	Opcode( Instruction.RESi, 23, 0,      Reg_A ),

	Opcode( Instruction.SETi, 23, 0,      Reg_B ),
	Opcode( Instruction.SETi, 23, 0,      Reg_C ),
	Opcode( Instruction.SETi, 23, 0,      Reg_D ),
	Opcode( Instruction.SETi, 23, 0,      Reg_E ),
	Opcode( Instruction.SETi, 23, 0,      Reg_H ),
	Opcode( Instruction.SETi, 23, 0,      Reg_L ),
	Opcode( Instruction.SETi, 23, 0,      0 ),
	Opcode( Instruction.SETi, 23, 0,      Reg_A )
];

static immutable ubyte[256] parityTable =
[
	1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1,
	0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
	0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
	1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1,
	0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
	1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1,
	1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1,
	0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
	0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
	1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1,
	1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1,
	0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
	1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1,
	0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
	0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0,
	1, 0, 0, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1
];

static immutable string[Instruction.OpCount] sOpcodeNames =
[
	"ADC",
	"ADC",
	"ADD",
	"ADD",
	"AND",
	"BIT",
	"CALL",
	"CALL",
	"CALL",
	"CCF",
	"CP",
	"CPD",
	"CPDR",
	"CPI",
	"CPIR",
	"CPL",
	"DAA",
	"DEC",
	"DEC",
	"DEC",
	"DI",
	"DJNZ",
	"EI",
	"EX",
	"EX",
	"EX",
	"EXX",
	"HALT",
	"IM",
	"IN",
	"INC",
	"INC",
	"INC",
	"IND",
	"INDR",
	"INI",
	"INIR",
	"JP",
	"JP",
	"JP",
	"JR",
	"JR",
	"JR",
	"LD",
	"LD",
	"LD",
	"LD",
	"LD",
	"LDD",
	"LDDR",
	"LDI",
	"LDIR",
	"NEG",
	"NOP",
	"OR",
	"OTDR",
	"OTIR",
	"OUT",
	"OUTD",
	"OUTI",
	"POP",
	"PUSH",
	"RES",
	"RES",
	"RET",
	"RET",
	"RET",
	"RETI",
	"RETN",
	"RL",
	"RLA",
	"RLC",
	"RLCA",
	"RLD",
	"RR",
	"RRA",
	"RRC",
	"RRCA",
	"RRD",
	"RST",
	"SBC",
	"SBC",
	"SCF",
	"SET",
	"SET",
	"SLA",
	"SLL",
	"SRA",
	"SRL",
	"SUB",
	"XOR"
];

static immutable RegisterInfo[] sRegInfo =
[
	RegisterInfo( "PC", 16, RegisterInfo.Flags.ProgramCounter, null ),
	RegisterInfo( "SP", 16, RegisterInfo.Flags.StackPointer, null ),

	RegisterInfo( "AF", 16, 0, null ),
	RegisterInfo( "BC", 16, 0, null ),
	RegisterInfo( "DE", 16, 0, null ),
	RegisterInfo( "HL", 16, 0, null ),
	RegisterInfo( "IX", 16, 0, null ),
	RegisterInfo( "IY", 16, 0, null ),
	RegisterInfo( "F", 8, RegisterInfo.Flags.FlagsRegister, "SZ?H?PNC" ),

	RegisterInfo( "AF'", 16, 0, null ),
	RegisterInfo( "BC'", 16, 0, null ),
	RegisterInfo( "DE'", 16, 0, null ),
	RegisterInfo( "HL'", 16, 0, null ),
	RegisterInfo( "F'", 8, RegisterInfo.Flags.FlagsRegister, "SZ?H?PNC" ),

	RegisterInfo( "I", 8, 0, null ),
	RegisterInfo( "R", 8, 0, null ),
];

static immutable int[] sDisplayRegs = [ 2, 3, 4, 5, 6, 7, 8, 1, 0 ];

static immutable AddressInfo[] sCodeLabels =
[
	AddressInfo(0x0000, "reset_0", null, SymbolType.CodeLabel ),
	AddressInfo(0x0008, "reset_8", null, SymbolType.CodeLabel ),
	AddressInfo(0x0010, "reset_10", null, SymbolType.CodeLabel ),
	AddressInfo(0x0018, "reset_18", null, SymbolType.CodeLabel ),
	AddressInfo(0x0020, "reset_20", null, SymbolType.CodeLabel ),
	AddressInfo(0x0028, "reset_28", null, SymbolType.CodeLabel ),
	AddressInfo(0x0030, "reset_30", null, SymbolType.CodeLabel ),
	AddressInfo(0x0038, "irq_handler", null, SymbolType.CodeLabel ),
	AddressInfo(0x0066, "nmi_handler", null, SymbolType.CodeLabel )
];

version(BigEndian)
	static string[] g8BitRegs = [ "?", "?", "?", "?", "A", "F", "B", "C", "D", "E", "H", "L", "IXH", "IXL", "IYH", "IYL", "I", "R", "A'", "F'", "B'", "C'", "D'", "E'", "H'", "L'", "M", "Z", "?", "PE", "?", "C", "P", "NZ", "?", "PO", "?", "NC" ];
else
	static string[] g8BitRegs = [ "?", "?", "?", "?", "F", "A", "C", "B", "E", "D", "L", "H", "IXL", "IXH", "IYL", "IYH", "R", "I", "F'", "A'", "C'", "B'", "E'", "D'", "L'", "H'", "M", "Z", "?", "PE", "?", "C", "P", "NZ", "?", "PO", "?", "NC" ];

static string[] g16BitRegs = [ "PC", "SP", "AF", "BC", "DE", "HL", "IX", "IY", "IR", "AF'", "BC'", "DE'", "HL'" ];
static immutable int[] g16BitRegIndexTable = [ 0, 1, 2, 3, 4, 5, 6, 7, 0, 9, 10, 11, 12 ];

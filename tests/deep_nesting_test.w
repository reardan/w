# wbuild: x64
/*
Genuinely nested control flow (a for whose body is another for, and so
on) used to trap at compile time: the codegen's ctrl region stacks
(code_generator/x86.w) were fixed int[256] arrays, and every open
if/while/for/switch region holds slots until it closes (2 per if, 3
per for), so 86 nested fors overflowed them with an index-out-of-
range trap. The stacks now grow dynamically, leaving the tokenizer's
200-unit statement-nesting guard as the only nesting bound.

Shapes (all measured against the pre-fix compiler):
  deep_for   95 nested single-iteration fors -- 285 ctrl slots at
             peak, past the old 256 bound (trapped at for #86
             before the fix); guard depth 1+2*95 = 191, under 200.
  deep_mixed 88 fors wrapping 9 ifs -- the if regions occupy ctrl
             slots 264..281, so if pushes too are exercised past the
             old bound (also trapped before the fix).
  deep_if    97 nested ifs, the deepest the front end permits: each
             genuinely nested level costs 2 statement-recursion units
             (the if and its ':' block both recurse statement()), so
             the 200-unit guard fires at 100 pure nested ifs -- below
             the old 129-if array bound. A pure if nest therefore
             cannot cross the old bound; deep_mixed covers that, and
             this shape pins the guard-max depth still executing
             correctly.

Each level increments a counter exactly once, so the asserted totals
prove every level's body ran. Generated programmatically.
*/
import lib.assert


int deep_for():
	int n = 0
	for int i0 in range(1):
		n = n + 1
		for int i1 in range(1):
			n = n + 1
			for int i2 in range(1):
				n = n + 1
				for int i3 in range(1):
					n = n + 1
					for int i4 in range(1):
						n = n + 1
						for int i5 in range(1):
							n = n + 1
							for int i6 in range(1):
								n = n + 1
								for int i7 in range(1):
									n = n + 1
									for int i8 in range(1):
										n = n + 1
										for int i9 in range(1):
											n = n + 1
											for int i10 in range(1):
												n = n + 1
												for int i11 in range(1):
													n = n + 1
													for int i12 in range(1):
														n = n + 1
														for int i13 in range(1):
															n = n + 1
															for int i14 in range(1):
																n = n + 1
																for int i15 in range(1):
																	n = n + 1
																	for int i16 in range(1):
																		n = n + 1
																		for int i17 in range(1):
																			n = n + 1
																			for int i18 in range(1):
																				n = n + 1
																				for int i19 in range(1):
																					n = n + 1
																					for int i20 in range(1):
																						n = n + 1
																						for int i21 in range(1):
																							n = n + 1
																							for int i22 in range(1):
																								n = n + 1
																								for int i23 in range(1):
																									n = n + 1
																									for int i24 in range(1):
																										n = n + 1
																										for int i25 in range(1):
																											n = n + 1
																											for int i26 in range(1):
																												n = n + 1
																												for int i27 in range(1):
																													n = n + 1
																													for int i28 in range(1):
																														n = n + 1
																														for int i29 in range(1):
																															n = n + 1
																															for int i30 in range(1):
																																n = n + 1
																																for int i31 in range(1):
																																	n = n + 1
																																	for int i32 in range(1):
																																		n = n + 1
																																		for int i33 in range(1):
																																			n = n + 1
																																			for int i34 in range(1):
																																				n = n + 1
																																				for int i35 in range(1):
																																					n = n + 1
																																					for int i36 in range(1):
																																						n = n + 1
																																						for int i37 in range(1):
																																							n = n + 1
																																							for int i38 in range(1):
																																								n = n + 1
																																								for int i39 in range(1):
																																									n = n + 1
																																									for int i40 in range(1):
																																										n = n + 1
																																										for int i41 in range(1):
																																											n = n + 1
																																											for int i42 in range(1):
																																												n = n + 1
																																												for int i43 in range(1):
																																													n = n + 1
																																													for int i44 in range(1):
																																														n = n + 1
																																														for int i45 in range(1):
																																															n = n + 1
																																															for int i46 in range(1):
																																																n = n + 1
																																																for int i47 in range(1):
																																																	n = n + 1
																																																	for int i48 in range(1):
																																																		n = n + 1
																																																		for int i49 in range(1):
																																																			n = n + 1
																																																			for int i50 in range(1):
																																																				n = n + 1
																																																				for int i51 in range(1):
																																																					n = n + 1
																																																					for int i52 in range(1):
																																																						n = n + 1
																																																						for int i53 in range(1):
																																																							n = n + 1
																																																							for int i54 in range(1):
																																																								n = n + 1
																																																								for int i55 in range(1):
																																																									n = n + 1
																																																									for int i56 in range(1):
																																																										n = n + 1
																																																										for int i57 in range(1):
																																																											n = n + 1
																																																											for int i58 in range(1):
																																																												n = n + 1
																																																												for int i59 in range(1):
																																																													n = n + 1
																																																													for int i60 in range(1):
																																																														n = n + 1
																																																														for int i61 in range(1):
																																																															n = n + 1
																																																															for int i62 in range(1):
																																																																n = n + 1
																																																																for int i63 in range(1):
																																																																	n = n + 1
																																																																	for int i64 in range(1):
																																																																		n = n + 1
																																																																		for int i65 in range(1):
																																																																			n = n + 1
																																																																			for int i66 in range(1):
																																																																				n = n + 1
																																																																				for int i67 in range(1):
																																																																					n = n + 1
																																																																					for int i68 in range(1):
																																																																						n = n + 1
																																																																						for int i69 in range(1):
																																																																							n = n + 1
																																																																							for int i70 in range(1):
																																																																								n = n + 1
																																																																								for int i71 in range(1):
																																																																									n = n + 1
																																																																									for int i72 in range(1):
																																																																										n = n + 1
																																																																										for int i73 in range(1):
																																																																											n = n + 1
																																																																											for int i74 in range(1):
																																																																												n = n + 1
																																																																												for int i75 in range(1):
																																																																													n = n + 1
																																																																													for int i76 in range(1):
																																																																														n = n + 1
																																																																														for int i77 in range(1):
																																																																															n = n + 1
																																																																															for int i78 in range(1):
																																																																																n = n + 1
																																																																																for int i79 in range(1):
																																																																																	n = n + 1
																																																																																	for int i80 in range(1):
																																																																																		n = n + 1
																																																																																		for int i81 in range(1):
																																																																																			n = n + 1
																																																																																			for int i82 in range(1):
																																																																																				n = n + 1
																																																																																				for int i83 in range(1):
																																																																																					n = n + 1
																																																																																					for int i84 in range(1):
																																																																																						n = n + 1
																																																																																						for int i85 in range(1):
																																																																																							n = n + 1
																																																																																							for int i86 in range(1):
																																																																																								n = n + 1
																																																																																								for int i87 in range(1):
																																																																																									n = n + 1
																																																																																									for int i88 in range(1):
																																																																																										n = n + 1
																																																																																										for int i89 in range(1):
																																																																																											n = n + 1
																																																																																											for int i90 in range(1):
																																																																																												n = n + 1
																																																																																												for int i91 in range(1):
																																																																																													n = n + 1
																																																																																													for int i92 in range(1):
																																																																																														n = n + 1
																																																																																														for int i93 in range(1):
																																																																																															n = n + 1
																																																																																															for int i94 in range(1):
																																																																																																n = n + 1
	return n


int deep_mixed():
	int n = 0
	for int m0 in range(1):
		n = n + 1
		for int m1 in range(1):
			n = n + 1
			for int m2 in range(1):
				n = n + 1
				for int m3 in range(1):
					n = n + 1
					for int m4 in range(1):
						n = n + 1
						for int m5 in range(1):
							n = n + 1
							for int m6 in range(1):
								n = n + 1
								for int m7 in range(1):
									n = n + 1
									for int m8 in range(1):
										n = n + 1
										for int m9 in range(1):
											n = n + 1
											for int m10 in range(1):
												n = n + 1
												for int m11 in range(1):
													n = n + 1
													for int m12 in range(1):
														n = n + 1
														for int m13 in range(1):
															n = n + 1
															for int m14 in range(1):
																n = n + 1
																for int m15 in range(1):
																	n = n + 1
																	for int m16 in range(1):
																		n = n + 1
																		for int m17 in range(1):
																			n = n + 1
																			for int m18 in range(1):
																				n = n + 1
																				for int m19 in range(1):
																					n = n + 1
																					for int m20 in range(1):
																						n = n + 1
																						for int m21 in range(1):
																							n = n + 1
																							for int m22 in range(1):
																								n = n + 1
																								for int m23 in range(1):
																									n = n + 1
																									for int m24 in range(1):
																										n = n + 1
																										for int m25 in range(1):
																											n = n + 1
																											for int m26 in range(1):
																												n = n + 1
																												for int m27 in range(1):
																													n = n + 1
																													for int m28 in range(1):
																														n = n + 1
																														for int m29 in range(1):
																															n = n + 1
																															for int m30 in range(1):
																																n = n + 1
																																for int m31 in range(1):
																																	n = n + 1
																																	for int m32 in range(1):
																																		n = n + 1
																																		for int m33 in range(1):
																																			n = n + 1
																																			for int m34 in range(1):
																																				n = n + 1
																																				for int m35 in range(1):
																																					n = n + 1
																																					for int m36 in range(1):
																																						n = n + 1
																																						for int m37 in range(1):
																																							n = n + 1
																																							for int m38 in range(1):
																																								n = n + 1
																																								for int m39 in range(1):
																																									n = n + 1
																																									for int m40 in range(1):
																																										n = n + 1
																																										for int m41 in range(1):
																																											n = n + 1
																																											for int m42 in range(1):
																																												n = n + 1
																																												for int m43 in range(1):
																																													n = n + 1
																																													for int m44 in range(1):
																																														n = n + 1
																																														for int m45 in range(1):
																																															n = n + 1
																																															for int m46 in range(1):
																																																n = n + 1
																																																for int m47 in range(1):
																																																	n = n + 1
																																																	for int m48 in range(1):
																																																		n = n + 1
																																																		for int m49 in range(1):
																																																			n = n + 1
																																																			for int m50 in range(1):
																																																				n = n + 1
																																																				for int m51 in range(1):
																																																					n = n + 1
																																																					for int m52 in range(1):
																																																						n = n + 1
																																																						for int m53 in range(1):
																																																							n = n + 1
																																																							for int m54 in range(1):
																																																								n = n + 1
																																																								for int m55 in range(1):
																																																									n = n + 1
																																																									for int m56 in range(1):
																																																										n = n + 1
																																																										for int m57 in range(1):
																																																											n = n + 1
																																																											for int m58 in range(1):
																																																												n = n + 1
																																																												for int m59 in range(1):
																																																													n = n + 1
																																																													for int m60 in range(1):
																																																														n = n + 1
																																																														for int m61 in range(1):
																																																															n = n + 1
																																																															for int m62 in range(1):
																																																																n = n + 1
																																																																for int m63 in range(1):
																																																																	n = n + 1
																																																																	for int m64 in range(1):
																																																																		n = n + 1
																																																																		for int m65 in range(1):
																																																																			n = n + 1
																																																																			for int m66 in range(1):
																																																																				n = n + 1
																																																																				for int m67 in range(1):
																																																																					n = n + 1
																																																																					for int m68 in range(1):
																																																																						n = n + 1
																																																																						for int m69 in range(1):
																																																																							n = n + 1
																																																																							for int m70 in range(1):
																																																																								n = n + 1
																																																																								for int m71 in range(1):
																																																																									n = n + 1
																																																																									for int m72 in range(1):
																																																																										n = n + 1
																																																																										for int m73 in range(1):
																																																																											n = n + 1
																																																																											for int m74 in range(1):
																																																																												n = n + 1
																																																																												for int m75 in range(1):
																																																																													n = n + 1
																																																																													for int m76 in range(1):
																																																																														n = n + 1
																																																																														for int m77 in range(1):
																																																																															n = n + 1
																																																																															for int m78 in range(1):
																																																																																n = n + 1
																																																																																for int m79 in range(1):
																																																																																	n = n + 1
																																																																																	for int m80 in range(1):
																																																																																		n = n + 1
																																																																																		for int m81 in range(1):
																																																																																			n = n + 1
																																																																																			for int m82 in range(1):
																																																																																				n = n + 1
																																																																																				for int m83 in range(1):
																																																																																					n = n + 1
																																																																																					for int m84 in range(1):
																																																																																						n = n + 1
																																																																																						for int m85 in range(1):
																																																																																							n = n + 1
																																																																																							for int m86 in range(1):
																																																																																								n = n + 1
																																																																																								for int m87 in range(1):
																																																																																									n = n + 1
																																																																																									if (n == 88):
																																																																																										n = n + 1
																																																																																										if (n == 89):
																																																																																											n = n + 1
																																																																																											if (n == 90):
																																																																																												n = n + 1
																																																																																												if (n == 91):
																																																																																													n = n + 1
																																																																																													if (n == 92):
																																																																																														n = n + 1
																																																																																														if (n == 93):
																																																																																															n = n + 1
																																																																																															if (n == 94):
																																																																																																n = n + 1
																																																																																																if (n == 95):
																																																																																																	n = n + 1
																																																																																																	if (n == 96):
																																																																																																		n = n + 1
	return n


int deep_if():
	int n = 0
	if (n == 0):
		n = n + 1
		if (n == 1):
			n = n + 1
			if (n == 2):
				n = n + 1
				if (n == 3):
					n = n + 1
					if (n == 4):
						n = n + 1
						if (n == 5):
							n = n + 1
							if (n == 6):
								n = n + 1
								if (n == 7):
									n = n + 1
									if (n == 8):
										n = n + 1
										if (n == 9):
											n = n + 1
											if (n == 10):
												n = n + 1
												if (n == 11):
													n = n + 1
													if (n == 12):
														n = n + 1
														if (n == 13):
															n = n + 1
															if (n == 14):
																n = n + 1
																if (n == 15):
																	n = n + 1
																	if (n == 16):
																		n = n + 1
																		if (n == 17):
																			n = n + 1
																			if (n == 18):
																				n = n + 1
																				if (n == 19):
																					n = n + 1
																					if (n == 20):
																						n = n + 1
																						if (n == 21):
																							n = n + 1
																							if (n == 22):
																								n = n + 1
																								if (n == 23):
																									n = n + 1
																									if (n == 24):
																										n = n + 1
																										if (n == 25):
																											n = n + 1
																											if (n == 26):
																												n = n + 1
																												if (n == 27):
																													n = n + 1
																													if (n == 28):
																														n = n + 1
																														if (n == 29):
																															n = n + 1
																															if (n == 30):
																																n = n + 1
																																if (n == 31):
																																	n = n + 1
																																	if (n == 32):
																																		n = n + 1
																																		if (n == 33):
																																			n = n + 1
																																			if (n == 34):
																																				n = n + 1
																																				if (n == 35):
																																					n = n + 1
																																					if (n == 36):
																																						n = n + 1
																																						if (n == 37):
																																							n = n + 1
																																							if (n == 38):
																																								n = n + 1
																																								if (n == 39):
																																									n = n + 1
																																									if (n == 40):
																																										n = n + 1
																																										if (n == 41):
																																											n = n + 1
																																											if (n == 42):
																																												n = n + 1
																																												if (n == 43):
																																													n = n + 1
																																													if (n == 44):
																																														n = n + 1
																																														if (n == 45):
																																															n = n + 1
																																															if (n == 46):
																																																n = n + 1
																																																if (n == 47):
																																																	n = n + 1
																																																	if (n == 48):
																																																		n = n + 1
																																																		if (n == 49):
																																																			n = n + 1
																																																			if (n == 50):
																																																				n = n + 1
																																																				if (n == 51):
																																																					n = n + 1
																																																					if (n == 52):
																																																						n = n + 1
																																																						if (n == 53):
																																																							n = n + 1
																																																							if (n == 54):
																																																								n = n + 1
																																																								if (n == 55):
																																																									n = n + 1
																																																									if (n == 56):
																																																										n = n + 1
																																																										if (n == 57):
																																																											n = n + 1
																																																											if (n == 58):
																																																												n = n + 1
																																																												if (n == 59):
																																																													n = n + 1
																																																													if (n == 60):
																																																														n = n + 1
																																																														if (n == 61):
																																																															n = n + 1
																																																															if (n == 62):
																																																																n = n + 1
																																																																if (n == 63):
																																																																	n = n + 1
																																																																	if (n == 64):
																																																																		n = n + 1
																																																																		if (n == 65):
																																																																			n = n + 1
																																																																			if (n == 66):
																																																																				n = n + 1
																																																																				if (n == 67):
																																																																					n = n + 1
																																																																					if (n == 68):
																																																																						n = n + 1
																																																																						if (n == 69):
																																																																							n = n + 1
																																																																							if (n == 70):
																																																																								n = n + 1
																																																																								if (n == 71):
																																																																									n = n + 1
																																																																									if (n == 72):
																																																																										n = n + 1
																																																																										if (n == 73):
																																																																											n = n + 1
																																																																											if (n == 74):
																																																																												n = n + 1
																																																																												if (n == 75):
																																																																													n = n + 1
																																																																													if (n == 76):
																																																																														n = n + 1
																																																																														if (n == 77):
																																																																															n = n + 1
																																																																															if (n == 78):
																																																																																n = n + 1
																																																																																if (n == 79):
																																																																																	n = n + 1
																																																																																	if (n == 80):
																																																																																		n = n + 1
																																																																																		if (n == 81):
																																																																																			n = n + 1
																																																																																			if (n == 82):
																																																																																				n = n + 1
																																																																																				if (n == 83):
																																																																																					n = n + 1
																																																																																					if (n == 84):
																																																																																						n = n + 1
																																																																																						if (n == 85):
																																																																																							n = n + 1
																																																																																							if (n == 86):
																																																																																								n = n + 1
																																																																																								if (n == 87):
																																																																																									n = n + 1
																																																																																									if (n == 88):
																																																																																										n = n + 1
																																																																																										if (n == 89):
																																																																																											n = n + 1
																																																																																											if (n == 90):
																																																																																												n = n + 1
																																																																																												if (n == 91):
																																																																																													n = n + 1
																																																																																													if (n == 92):
																																																																																														n = n + 1
																																																																																														if (n == 93):
																																																																																															n = n + 1
																																																																																															if (n == 94):
																																																																																																n = n + 1
																																																																																																if (n == 95):
																																																																																																	n = n + 1
																																																																																																	if (n == 96):
																																																																																																		n = n + 1
	return n


int main():
	asserts(c"deep_for runs all 95 levels", deep_for() == 95)
	asserts(c"deep_mixed runs all 97 levels", deep_mixed() == 97)
	asserts(c"deep_if reaches depth 97", deep_if() == 97)
	println2(c"deep_nesting_test passed")
	return 0

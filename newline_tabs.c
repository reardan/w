
		while (token[j] != '"'):
			if (token[j] == 92):
				# Hex Values:
				if (token[j + 1] == 'x'):
					if (token[j + 2] <= '9'):
						k = token[j + 2] - '0'
					else:
						k = token[j + 2] - 'a' + 10
					k = k << 4
					if (token[j + 3] <= '9'):
						k = k + token[j + 3] - '0'
					else:
						k = k + token[j + 3] - 'a' + 10
					token[i] = k
					j = j + 4

				else:
					if (token[j + 1] == 'n'):
						token[i] = 10
					else if (token[j + 1] == 't'):
						token[i] = 9
					else:
						token[i] = token[j + 1]
					j = j + 2


			else:
				token[i] = token[j]
				j = j + 1

			i = i + 1
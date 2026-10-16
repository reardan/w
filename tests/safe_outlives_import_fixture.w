# Named result-only labels are bound by explicit outlives clauses.
ref[shorter] int* outlives_import(ref[longer] int* p) where longer > shorter:
	return p

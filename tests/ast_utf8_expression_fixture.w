struct Café:
	int größe
	int 数量

enum Farbe:
	ROT
	GRÜN
	BLAU

T erstes[T](T ερώτηση): return ερώτηση
int 合計(Café* c): return c.größe + c.数量

int main():
	int π = 3
	int 日本 = 4
	int 🎉 = (π + 日本)
	if (🎉 != 7): return 1
	Café café = Café(π, 日本)
	if (合計(&café) != 7): return 2
	café.größe += 2
	if (café.größe != 5): return 3
	if (erstes[int](🎉) != 7 || erstes(日本) != 4): return 4
	list[int] λίστα = list[int]{π, 日本, 🎉}
	if (λίστα[2] != 7): return 5
	map[int, int] κλειδιά = map[int, int]{π: 日本}
	if (κλειδιά[π] != 4): return 6
	Farbe χρώμα = GRÜN
	if (χρώμα != GRÜN): return 7
	string text = f"{π}:{日本}:{🎉}:{café.größe}"
	if (text != s"3:4:7:5"): return 8
	λίστα.free()
	κλειδιά.free()
	return 0

import structures.w_list


int calendar_isleap(int year):
	if ((year % 4) != 0):
		return 0
	if ((year % 100) != 0):
		return 1
	if ((year % 400) == 0):
		return 1
	return 0


int calendar_days_in_month(int year, int month):
	if (month == 2):
		if (calendar_isleap(year)):
			return 29
		return 28
	if ((month == 4) | (month == 6) | (month == 9) | (month == 11)):
		return 30
	return 31


int calendar_date_valid(int year, int month, int day):
	if (year < 1):
		return 0
	if ((month < 1) | (month > 12)):
		return 0
	if ((day < 1) | (day > calendar_days_in_month(year, month))):
		return 0
	return 1


int calendar_days_before_year(int year):
	int y = year - 1
	return y * 365 + y / 4 - y / 100 + y / 400


int calendar_days_before_month(int year, int month):
	int days = 0
	int m = 1
	while (m < month):
		days = days + calendar_days_in_month(year, m)
		m = m + 1
	return days


int calendar_ordinal(int year, int month, int day):
	if (calendar_date_valid(year, month, day) == 0):
		return 0
	return calendar_days_before_year(year) + calendar_days_before_month(year, month) + day


# Monday=0, Sunday=6, matching Python datetime.date.weekday().
int calendar_weekday(int year, int month, int day):
	int ordinal = calendar_ordinal(year, month, day)
	if (ordinal == 0):
		return -1
	return (ordinal + 6) % 7


int calendar_monthrange(int year, int month, int* weekday, int* days):
	if ((year < 1) | (month < 1) | (month > 12)):
		return 0
	weekday[0] = calendar_weekday(year, month, 1)
	days[0] = calendar_days_in_month(year, month)
	return 1


list[list[int]] calendar_monthcalendar(int year, int month):
	list[list[int]] weeks = new list[list[int]]
	int first_weekday = 0
	int days_in_month = 0
	if (calendar_monthrange(year, month, &first_weekday, &days_in_month) == 0):
		return weeks

	int day = 1
	int column = 0
	list[int] week = new list[int]
	while (column < first_weekday):
		week.push(0)
		column = column + 1
	while (day <= days_in_month):
		week.push(day)
		column = column + 1
		day = day + 1
		if (column == 7):
			weeks.push(week)
			week = new list[int]
			column = 0
	if (column > 0):
		while (column < 7):
			week.push(0)
			column = column + 1
		weeks.push(week)
	return weeks

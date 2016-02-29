/*
Testing Grounds for the W Language
*/

/* Our library functions. */
void exit(int);
int getchar(void);
void *malloc(int);
int putchar(int);
int puterror(int);

/* The first thing defined must be main(). */
int main1();
int main():
	return main1()

void print(char *s):
	int i = 0
	while(s[i]):
		putchar(s[i])
		i = i + 1

int strlen(char *c):
	int length = 0
	while(c[length]):
		length = length + 1
	return length

void reverse(char *s):
	int i = 0
	int j = strlen(s)-1
	int c
	while(i < j):
		c = s[i]
		s[i] = s[j]
		s[j] = c
		i = i + 1
		j = j -1

char* itoa(int n):
	char *s = "012345678901234567890"
	int i
	int sign = n
	if(n < 0):
		n = 0-n
	i = 0
	while(n > 0):
		s[i] = n % 10 + '0'
		i = i + 1
		n = n / 10
	if(sign < 0):
		s[i] = '-'
		i = i + 1
	s[i] = 0
	reverse(s)
	return s


/* Grounds Start */
/*int main1():
	int a = '0'
	a = a + strlen("hi there")
	putchar(a)
	putchar(10)

	print(itoa(11))
	putchar(10)

	return 0*/



int range(int end):
	int i = 0
	if (i <= end):
		i = i + 1
		return i


int main1():
	int a = '0'
	for int x in range(10):
		puterror(0 + x)
	char *s = "\x0ahi thar\x0a"
	syscall(4,2,s,strlen(s))
	return 0

/*
int main1():
	int a = 7
	int b = 3
	int c = a % b
	c = c + '0'
	int d = 1 + 2 * 2
	d = d + '0'
	putchar('"')
	putchar(d)
	putchar('"')
	putchar(10)

	return 0
*/
/*
int main1():
	int a
	
	a = '9'
	while(a >= '0'):
		putchar(a)
		a = a - 1
	putchar(10)
	
	a = '0'
	while(a <= '9'):
		putchar(a)
		a = a + 1
	putchar(10)

	return 0*/

/* Grounds End */

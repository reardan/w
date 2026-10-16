grammar End;
start: (A CR)* EOF;
A: 'a';
CR: '\n' | EOF;

var total=0; outer: inner: for (let i=0; i<3; i++) { for (const j of [1,2]) { total+=j; continue outer; } total=99; } total;

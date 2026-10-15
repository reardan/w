const object = {answer: 42, method: function() { return () => this.answer; }}; const callback = object.method(); const other = {answer: 7, callback}; other.callback();

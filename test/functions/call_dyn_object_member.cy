use test

type Foo:
    member dyn

    func foo(self):
        return self.member()

var f = Foo{member=() => 3}  
test.eq(f.foo(), 3)

--cytest: pass
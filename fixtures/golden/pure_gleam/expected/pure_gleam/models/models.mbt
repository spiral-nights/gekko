///|
#derive(Eq, Debug, Hash)
pub(all) enum User {
  Admin(id~ : Int64, name~ : String, level~ : Int64)
  Guest(id~ : Int64, name~ : String)
}

///|
pub impl @gprelude.GleamInspect for User with gleam_inspect(self) {
  match self {
    Admin(id=f0, name=f1, level=f2) => "Admin(" + @gprelude.GleamInspect::gleam_inspect(f0) + ", " + @gprelude.GleamInspect::gleam_inspect(f1) + ", " + @gprelude.GleamInspect::gleam_inspect(f2) + ")"
    Guest(id=f0, name=f1) => "Guest(" + @gprelude.GleamInspect::gleam_inspect(f0) + ", " + @gprelude.GleamInspect::gleam_inspect(f1) + ")"
  }
}

///|
#derive(Eq, Debug, Hash)
pub(all) enum Point {
  Point(x~ : Double, y~ : Double)
}

///|
pub impl @gprelude.GleamInspect for Point with gleam_inspect(self) {
  match self {
    Point(x=f0, y=f1) => "Point(" + @gprelude.GleamInspect::gleam_inspect(f0) + ", " + @gprelude.GleamInspect::gleam_inspect(f1) + ")"
  }
}

///|
#derive(Eq, Debug, Hash)
pub(all) enum Box[A] {
  Box(value~ : A, label~ : String)
}

///|
pub impl[A : @gprelude.GleamInspect] @gprelude.GleamInspect for Box[A] with gleam_inspect(self) {
  match self {
    Box(value=f0, label=f1) => "Box(" + @gprelude.GleamInspect::gleam_inspect(f0) + ", " + @gprelude.GleamInspect::gleam_inspect(f1) + ")"
  }
}

///|
pub(all) enum Hook {
  Hook(cb~ : (Int64) -> Int64)
}

///|
pub impl @gprelude.GleamInspect for Hook with gleam_inspect(self) {
  match self {
    Hook(cb=_) => "Hook(" + "\"//fn(...) { ... }\"" + ")"
  }
}

///|
pub fn User::id(self : User) -> Int64 {
  match self {
    Admin(id~, ..) => id
    Guest(id~, ..) => id
  }
}

///|
pub fn User::name(self : User) -> String {
  match self {
    Admin(name~, ..) => name
    Guest(name~, ..) => name
  }
}

///|
pub fn Point::x(self : Point) -> Double {
  match self {
    Point(x~, ..) => x
  }
}

///|
pub fn Point::y(self : Point) -> Double {
  match self {
    Point(y~, ..) => y
  }
}

///|
pub fn[A] Box::label(self : Box[A]) -> String {
  match self {
    Box(label~, ..) => label
  }
}

///|
pub fn[A] Box::value(self : Box[A]) -> A {
  match self {
    Box(value~, ..) => value
  }
}

///|
pub fn Hook::cb(self : Hook) -> (Int64) -> Int64 {
  match self {
    Hook(cb~, ..) => cb
  }
}

///|
pub fn make_admin(id : Int64, name : String) -> User {
  Admin(id=id, name=name, level=1L)
}

///|
pub fn promote(user : User, new_level : Int64) -> User {
  match user {
    Admin(..) => match user {
      Admin(id=__upd_0_id, name=__upd_0_name, level=_) => Admin(id=__upd_0_id, name=__upd_0_name, level=new_level)
      _ => @prelude.abort("unreachable record update variant")
    }
    Guest(id~, name~) => Admin(id=id, name=name, level=new_level)
  }
}

///|
pub fn shift_x(p : Point, dx : Double) -> Point {
  match p {
    Point(x=_, y=__upd_1_y) => Point(x=(p.x() + dx), y=__upd_1_y)
  }
}

------------------------------------------------------------------------------
--                             G N A T - L L V M                            --
--                                                                          --
--                     Copyright (C) 2013-2019, AdaCore                     --
--                                                                          --
-- This is free software;  you can redistribute it  and/or modify it  under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  This software is distributed in the hope  that it will be useful, --
-- but WITHOUT ANY WARRANTY;  without even the implied warranty of MERCHAN- --
-- TABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public --
-- License for  more details.  You should have  received  a copy of the GNU --
-- General  Public  License  distributed  with  this  software;   see  file --
-- COPYING3.  If not, go to http://www.gnu.org/licenses for a complete copy --
-- of the license.                                                          --
------------------------------------------------------------------------------

with Ada.Unchecked_Conversion;

with Repinfo; use Repinfo;
with Sinfo;   use Sinfo;

with LLVM.Core; use LLVM.Core;

with GNATLLVM.Environment; use GNATLLVM.Environment;
with GNATLLVM.GLValue;     use GNATLLVM.GLValue;
with GNATLLVM.Utils;       use GNATLLVM.Utils;

package GNATLLVM.Types is

   --  Our strategy for handling types is very different from what's done by
   --  Gigi in the GCC implementation of GNAT.  Here, we never pass a type
   --  to any function that expects a type unless that type is the fullest
   --  possible view.
   --
   --  We also ignore freeze nodes for types.  We can safely do this
   --  because we don't actually do anything with an expression used as a
   --  bound of the type other than putting the tree node for that
   --  expression into a data structure.  The expression itself isn't
   --  evaluated until an object of the type is referenced (or some other
   --  operation that freezes the type).  We can safely do this because the
   --  front end has removed all side effects from type bounds and other
   --  constraints.
   --
   --  Finally, we always use a recursive algorithm to define types,
   --  whether they're external or internal.  This means we have to "break
   --  the loop" when there's a reference back to a type (such as a record
   --  or array with an access type to itself).  We do this by looking at
   --  whether the designated type of an access type depends on something
   --  that's being elaborated and, if so, make a dummy access type of the
   --  same width and structure.  For a designated type that's a record,
   --  that dummy type will actually be the type of the record.  For scalar
   --  types, we can fully elaborate the type and access to function types
   --  always use void pointers, so don't depend on the designated type.
   --
   --  This means the only cases where we need a dummy type are the less
   --  common cases of an array and access type.  We've also arranged
   --  things so that the only place this dummy can show up is as the
   --  component of a record, the component type of an array, or the
   --  designated type of an access type.  So whenever we get one of those,
   --  we check for the need to convert to the actual access type and not
   --  the dummy one.

   Max_Load_Size : constant := 8;
   --  LLVM supports loading and storing of arbitrarily-large values, but
   --  code generation and optimization is very slow if the value's size is
   --  too large.  We pick an arbitary constant here to cut it off.  This
   --  constant is in number of loads or stores, meaning the maximum value
   --  of the size divided by the alignment.  ??? Perhaps we should make
   --  this a command-line operand.

   function Is_Dynamic_Size
     (GT : GL_Type; Max_Size : Boolean := False) return Boolean
     with Pre => Present (GT);
   --  Returns True if GT's size is not known at compile-time.  Max_Size
   --  is True if we're to consider the maximum size of GT's type.

   function Create_Access_Type_To (GT : GL_Type) return Type_T is
     (Type_For_Relationship (GT, Relationship_For_Ref (GT)))
     with Pre => Present (GT), Post => Present (Create_Access_Type_To'Result);
   --  Function that creates the access type for a corresponding type. Since
   --  access types are not just pointers, this is the abstraction bridge
   --  between the two.  Note that we need not have a GNAT type corresponding
   --  to this access type, which makes this different than calling
   --  Type_Of on an access to GT.

   function Type_Of (TE : Entity_Id) return Type_T
     with Pre  => Present (TE) and then TE = Get_Fullest_View (TE),
          Post => Present (Type_Of'Result);
   --  Given a GNAT type TE, return the corresponding LLVM type, building
   --  it and a GL_Type first if necessary.

   procedure Copy_Annotations (In_TE, Out_TE : Entity_Id)
     with Pre => Is_Type (In_TE) and then Is_Type (Out_TE)
                 and then In_TE = Get_Fullest_View (Out_TE);
   --  Copy any annotations we made from In_TE to Out_TE

   function Create_TBAA (TE : Entity_Id) return Metadata_T
     with Pre => Is_Type_Or_Void (TE);

   procedure Bounds_From_Type (GT : GL_Type; Low, High : out GL_Value)
     with Pre => Present (GT), Post => Present (Low) and then Present (High);

   procedure Push_LValue_List;
   procedure Pop_LValue_List;
   --  Push and pop the active range of the LValue pair list

   procedure Clear_LValue_List;
   --  Remove all entries previously added to the LValue list

   procedure Add_To_LValue_List (V : GL_Value)
     with Pre => Present (V);
   --  Add V to the list that's searched by Get_Matching_Value

   function Add_To_LValue_List (V : GL_Value) return GL_Value
     with Pre => Present (V), Post => Add_To_LValue_List'Result = V;
   --  Likewise, but return V

   function Get_Matching_Value (TE : Entity_Id) return GL_Value
     with Pre  => Is_Type (TE),
          Post => Present (Get_Matching_Value'Result);
   --  Find a value that's being computed by the current Emit_LValue
   --  recursion that has the same base type as T.

   function Int_Ty (Num_Bits : Nat) return Type_T is
     (Int_Type (unsigned (Num_Bits)))
     with Post => Get_Type_Kind (Int_Ty'Result) = Integer_Type_Kind;

   function Int_Ty (Num_Bits : Uint) return Type_T is
     (Int_Type (unsigned (UI_To_Int (Num_Bits))))
     with Post => Get_Type_Kind (Int_Ty'Result) = Integer_Type_Kind;

   function Fn_Ty
     (Param_Ty : Type_Array;
      Ret_Ty   : Type_T;
      Varargs  : Boolean := False) return Type_T is
     (Function_Type
        (Ret_Ty, Param_Ty'Address, Param_Ty'Length, Varargs))
     with Pre  => Present (Ret_Ty),
          Post => Get_Type_Kind (Fn_Ty'Result) = Function_Type_Kind;

   function Build_Struct_Type
     (Types : Type_Array; Packed : Boolean := False) return Type_T
     with Post => Present (Build_Struct_Type'Result);
   --  Build an LLVM struct type containing the specified types

   function Get_Fullest_View
     (TE : Entity_Id; Include_PAT : Boolean := True) return Entity_Id
     with Pre => Is_Type_Or_Void (TE),
          Post => Is_Type_Or_Void (Get_Fullest_View'Result);
   --  Get the fullest possible view of E, looking through private,
   --  limited, packed array and other implementation types.  If Include_PAT
   --  is True, don't look inside packed array types.

   function Full_Base_Type
     (TE : Entity_Id; For_Orig : Boolean := False) return Entity_Id
   is
     (Get_Fullest_View (Implementation_Base_Type (TE), not For_Orig))
     with Pre  => Is_Type_Or_Void (TE),
          Post => Present (Full_Base_Type'Result);

   function Is_Full_Base_Type (TE : Entity_Id) return Boolean is
     (Full_Base_Type (TE) = TE)
     with Pre => Is_Type_Or_Void (TE);
   --  True when TE is its own base type.  Similar, but not identical to
   --  the front-end function Is_Base_Type, which just tests the Ekind.

   function Ultimate_Base_Type (TE : Entity_Id) return Entity_Id
     with Pre => Is_Type (TE), Post => Is_Type (Ultimate_Base_Type'Result);
   --  Go up TE's Etype chain until it points to itself, which will
   --  go up both base and parent types.

   function Full_Etype (N : Node_Id) return Entity_Id is
     (if   Ekind (Etype (N)) = E_Void then Etype (N)
      else Get_Fullest_View (Etype (N)))
     with Pre => Present (N), Post => Is_Type_Or_Void (Full_Etype'Result);

   function Full_Entity (N : Node_Id) return Entity_Id is
     (Get_Fullest_View (Entity (N)))
     with Pre => Present (N), Post => Is_Type (Full_Entity'Result);

   function Full_Component_Type (TE : Entity_Id) return Entity_Id is
     (Get_Fullest_View (Component_Type (TE)))
     with Pre  => Is_Array_Type (TE),
          Post => Present (Full_Component_Type'Result);

   function Full_Original_Array_Type (TE : Entity_Id) return Entity_Id is
     (Get_Fullest_View (Original_Array_Type (TE), Include_PAT => False))
     with Pre  => Is_Packed_Array_Impl_Type (TE),
          Post => Is_Array_Type (Full_Original_Array_Type'Result);

   function Full_Designated_Type (TE : Entity_Id) return Entity_Id is
     (Get_Fullest_View (Designated_Type (TE)))
     with Pre  => Is_Access_Type (TE),
          Post => Present (Full_Designated_Type'Result);

   function Full_Scope (E : Entity_Id) return Entity_Id is
     (Get_Fullest_View (Scope (E)))
     with Pre => Present (E), Post => Present (Full_Scope'Result);

   function Full_Parent_Subtype (TE : Entity_Id) return Entity_Id is
     (Get_Fullest_View (Parent_Subtype (TE)))
     with Pre  => Is_Record_Type (TE),
          Post => Is_Record_Type (Full_Parent_Subtype'Result);

   function Is_Unconstrained_Record (TE : Entity_Id) return Boolean is
     (Ekind (TE) = E_Record_Type and then Has_Discriminants (TE))
     with Pre => Is_Type_Or_Void (TE);

   function Is_Unconstrained_Array (TE : Entity_Id) return Boolean is
     (Is_Array_Type (TE) and then not Is_Constrained (TE))
     with Pre => Is_Type_Or_Void (TE);

   function Is_Access_Unconstrained_Array (TE : Entity_Id) return Boolean is
     (Is_Access_Type (TE)
        and then Is_Unconstrained_Array (Full_Designated_Type (TE)))
     with Pre => Is_Type (TE);

   function Is_Unconstrained_Type (TE : Entity_Id) return Boolean is
     (Is_Unconstrained_Array (TE) or else Is_Unconstrained_Record (TE))
     with Pre => Is_Type_Or_Void (TE);

   function Is_Bit_Packed_Array_Impl_Type (TE : Entity_Id) return Boolean is
     (Is_Packed_Array_Impl_Type (TE)
        and then Is_Bit_Packed_Array (Original_Array_Type (TE)))
     with Pre => Is_Type (TE);

   function Is_Array_Or_Packed_Array_Type (TE : Entity_Id) return Boolean is
     (Is_Array_Type (TE) or else Is_Packed_Array_Impl_Type (TE))
     with Pre => Is_Type (TE);

   function Type_Needs_Bounds (TE : Entity_Id) return Boolean is
     ((Is_Constr_Subt_For_UN_Aliased (TE) and then Is_Array_Type (TE))
      or else (Is_Packed_Array_Impl_Type (TE)
                 and then Type_Needs_Bounds (Original_Array_Type (TE))))
     with Pre => Is_Type (TE);
   --  True is TE is a type that needs bounds stored with data

   function Get_Type_Size (T : Type_T) return ULL is
     (if   Get_Type_Kind (T) = Struct_Type_Kind
      then Store_Size_Of_Type (Module_Data_Layout, T)
      else ABI_Size_Of_Type (Module_Data_Layout, T))
     with Pre => Present (T);
     --  Return the size of an LLVM type, in bytes.  For structures, we want
     --  to return the actual size, not including padding, but for other types
     --  we need the size, including padding.  This is important for some
     --  of the FP types.

   function Get_Type_Size (T : Type_T) return GL_Value is
     (Size_Const_Int (Get_Type_Size (T)));
   --  Return the size of an LLVM type, in bytes, as an LLVM constant

   function Get_Type_Size_In_Bits (T : Type_T) return ULL is
     (Size_Of_Type_In_Bits (Module_Data_Layout, T))
     with Pre => Present (T);
   --  Return the size of an LLVM type, in bits

   function Get_Type_Size_In_Bits (V : GL_Value) return ULL is
     (Size_Of_Type_In_Bits (Module_Data_Layout, Type_Of (V.Value)))
     with Pre => Present (V);
   --  Return the size of an LLVM type, in bits

   function Get_Type_Size_In_Bits (T : Type_T) return GL_Value is
     (Const_Int (Size_GL_Type, Get_Type_Size_In_Bits (T), False))
     with Pre  => Present (T),
          Post => Present (Get_Type_Size_In_Bits'Result);
   --  Return the size of an LLVM type, in bits, as an LLVM constant

   function Get_Type_Size_In_Bits (GT : GL_Type) return GL_Value
     with Pre  => Present (GT),
          Post => Present (Get_Type_Size_In_Bits'Result);
   --  Likewise, but convert from a GNAT type

   function Get_Type_Size_In_Bits (V : GL_Value) return GL_Value
     with Pre  => Present (V),
          Post => Present (Get_Type_Size_In_Bits'Result);
   --  Variant of above to get type from a GL_Value

   function Get_Type_Alignment (T : Type_T) return ULL is
     (ULL (ABI_Alignment_Of_Type (Module_Data_Layout, T)))
     with Pre => Present (T);
   --  Return the size of an LLVM type, in bits

   function Get_Type_Alignment (T : Type_T) return GL_Value is
     (Size_Const_Int (Get_Type_Alignment (T)));
   --  Return the alignment of an LLVM type, in bytes, as an LLVM constant

   function Is_Loadable_Type (T : Type_T) return Boolean
     with Pre => Present (T);
   --  Used for the function below

   function Is_Loadable_Type (TE : Entity_Id) return Boolean is
     (not Is_Nonnative_Type (TE) and then Is_Loadable_Type (Type_Of (TE)))
     with Pre => Is_Type (TE);
   function Is_Loadable_Type (GT : GL_Type) return Boolean
     with Pre => Present (GT);
   --  Returns True if we should use a load/store instruction to copy values
   --  of this type.  We can't do this if it's of dynamic size, but LLVM
   --  also doesn't do well with large load/store instructions.

   function Allocate_For_Type
     (GT        : GL_Type;
      Alloc_GT  : GL_Type;
      N         : Node_Id;
      V         : GL_Value  := No_GL_Value;
      Expr      : Node_Id   := Empty;
      Def_Ident : Entity_Id := Empty;
      Name      : String    := "";
      Max_Size  : Boolean   := False) return GL_Value
     with Pre  => Present (GT) and then Present (Alloc_GT),
          Post => Is_Access_Type (Allocate_For_Type'Result);
   --  Allocate space on the stack for an object of type GT and return a
   --  pointer to the space.  Name is the name to use for the LLVM value.
   --  V, if Present, is a value to be copyied to the temporary and can be
   --  used to size the allocated space.  Likewise For Expr, but both Expr
   --  and V can't be Present.  N is a node used for a Sloc if we have to
   --  raise an exception.

   function Heap_Allocate_For_Type
     (GT        : GL_Type;
      Alloc_GT  : GL_Type;
      V         : GL_Value  := No_GL_Value;
      N         : Node_Id   := Empty;
      Expr      : Node_Id   := Empty;
      Proc      : Entity_Id := Empty;
      Pool      : Entity_Id := Empty;
      Def_Ident : Entity_Id := Empty;
      Max_Size  : Boolean   := False) return GL_Value
     with Pre  => Present (GT) and then Present (Alloc_GT)
                  and then (No (Proc) or else Present (Pool)),
          Post => Is_Access_Type (Heap_Allocate_For_Type'Result);
   --  Similarly, but allocate storage on the heap.  This handles default
   --  allocation, secondary stack, and storage pools.

   procedure Heap_Deallocate
     (V        : GL_Value;
      Desig_GT : GL_Type;
      Proc     : Entity_Id;
      Pool     : Entity_Id)
     with Pre => Present (V)
                 and then (No (Proc) or else Present (Pool));
   --  Free memory allocated by Heap_Allocate_For_Type

   function To_Size_Type (V : GL_Value) return GL_Value
     with Pre  => Present (V),
          Post => Type_Of (To_Size_Type'Result) = LLVM_Size_Type;
   --  Convert V to Size_Type.  This is always Size_Type's width, but may
   --  actually be a different GNAT type.

   function Get_Type_Alignment
     (GT : GL_Type; Use_Specified : Boolean := True) return ULL
     with Pre => Present (GT);
   --  Return the size of a type, in bits.  If Use_Specified is False,
   --  ignore a specified alignment.

   function Get_Type_Alignment
     (GT : GL_Type; Use_Specified : Boolean := True) return unsigned
   is
     (unsigned (ULL'(Get_Type_Alignment (GT, Use_Specified))))
     with Pre => Present (GT);

   function Get_Type_Size
     (GT         : GL_Type;
      V          : GL_Value := No_GL_Value;
      Max_Size   : Boolean  := False;
      No_Padding : Boolean  := False) return GL_Value
     with Pre => Present (GT), Post => Present (Get_Type_Size'Result);
   --  Return the size of a type, in bytes, as a GL_Value.  If TE is
   --  an unconstrained array type, V must be the value of the array.
   --  If Max_Size is true, we return the maximum size of the type.
   --  If No_Padding is true, we don't count any padding of the type.

   function Compute_Size
     (Left_GT, Right_GT       : GL_Type;
      Left_Value, Right_Value : GL_Value) return GL_Value
     with Pre  => Present (Left_GT) and then Present (Right_GT)
                  and then Present (Right_Value),
          Post =>  Present (Compute_Size'Result);
   --  Used for comparison and assignment: compute the size to be used in
   --  the operation.  Right_Value must be specified.  Left_Value is
   --  optional and will be specified in the comparison case, but not the
   --  assignment case.  If Right_Value is a discriminated record, we
   --  assume here that the last call to Emit_LValue was to compute
   --  Right_Value so that we can use Get_Matching_Value to return the
   --  proper object.  In the comparison case, where Left_Value is
   --  specified, we can only be comparing arrays, so we won't need to
   --  use Get_Matching_Value.

   function Get_Type_Size_Complexity
     (GT : GL_Type; Max_Size : Boolean := False) return Nat
     with Pre  => Present (GT);
   --  Return the complexity of computing the size of a type.  This roughly
   --  gives the number of "things" needed to access to compute the size.
   --  This returns zero iff the type is of a constant size.

   function Get_Attribute_From_Annotation (N : Node_Id) return Uint
     with Pre => Nkind (N) = N_Attribute_Reference;
   --  If the attribute referenced by N is known statically (either by being
   --  set by the front end or by us via back-annotation, return the value
   --  as a Uint.  Otherwise, return No_Uint.

   procedure Add_Type_Data_To_Instruction (Inst : Value_T; GT : GL_Type);
   --  Add type data (e.g., volatility and TBAA info) to an Instruction

   procedure Validate_And_Set_Alignment
     (E : Entity_Id; Align : Uint; Current_Align : ULL)
     with Pre => Present (E);
   --  Current_Align is the current alignment of E, either because it's
   --  the alignment of the LLVM type (if E is a type) or because it's the
   --  alignment of E's type (if E if an object).  Align is a proposed
   --  alignment for E.  See if it's valid (possibly issuing an error
   --  message if not) and set the alignment of E to that value or an
   --  acceptable value if Align isn't valid.

   --  In order to use the generic functions that computing sizing
   --  information to compute whether a size is dynamic, we need versions
   --  of the routines that actually compute the size that instead only
   --  record the size if it's a constant.  We use the data structure
   --  below.

   type IDS is record
      Is_None     : Boolean;
      Value       : GL_Value;
   end record;

   No_IDS  : constant IDS := (True,  No_GL_Value);
   Var_IDS : constant IDS := (False, No_GL_Value);

   function No      (V : IDS) return Boolean is (V =  No_IDS);
   function Present (V : IDS) return Boolean is (V /= No_IDS);

   function Is_Const  (V : IDS) return Boolean is (Present (V.Value));

   function Const (C : ULL; Sign_Extend : Boolean := False) return IDS is
     ((False,  Size_Const_Int (C, Sign_Extend)))
     with Post => Is_Const (Const'Result);

   function Const_Int (GT : GL_Type; C : Uint) return IDS is
     ((False, Const_Int (GT, C)))
     with Pre  => Present (GT) and then C /= No_Uint;

   function Const_Val_ULL (V : IDS) return ULL is
     (Get_Const_Int_Value_ULL (V.Value))
     with Pre => Is_Const (V);

   function Const_Int (V : IDS) return LLI is
     (Get_Const_Int_Value (V.Value))
     with Pre => Is_Const (V);

   function Get_Type_Size
     (GT         : GL_Type;
      V          : GL_Value := No_GL_Value;
      Max_Size   : Boolean  := False;
      No_Padding : Boolean  := False) return IDS
     with Pre => Present (GT), Post => Present (Get_Type_Size'Result);

   function I_Cmp
     (Op       : Int_Predicate_T;
      LHS, RHS : IDS;
      Name     : String := "") return IDS is
     (if   Is_Const (LHS) and then Is_Const (RHS)
      then (False, I_Cmp (Op, LHS.Value, RHS.Value, Name)) else Var_IDS)
     with Pre  => Present (LHS) and then Present (RHS),
          Post => Present (I_Cmp'Result);

   function Add (V1, V2 : IDS; Name : String := "") return IDS is
     (if   Is_Const (V1) and then Is_Const (V2)
      then (False, Add (V1.Value, V2.Value, Name)) else Var_IDS)
     with Pre  => Present (V1) and then Present (V2),
          Post => Present (Add'Result);

   function Sub (V1, V2 : IDS; Name : String := "") return IDS is
     (if   Is_Const (V1) and then Is_Const (V2)
      then (False, Sub (V1.Value, V2.Value, Name)) else Var_IDS)
     with Pre  => Present (V1) and then Present (V2),
          Post => Present (Sub'Result);

   function Mul (V1, V2 : IDS; Name : String := "") return IDS is
     (if   Is_Const (V1) and then Is_Const (V2)
      then (False, Mul (V1.Value, V2.Value, Name)) else Var_IDS)
     with Pre  => Present (V1) and then Present (V2),
          Post => Present (Mul'Result);

   function U_Div (V1, V2 : IDS; Name : String := "") return IDS is
     (if   Is_Const (V1) and then Is_Const (V2)
      then (False, U_Div (V1.Value, V2.Value, Name)) else Var_IDS)
     with Pre  => Present (V1) and then Present (V2),
          Post => Present (U_Div'Result);

   function S_Div (V1, V2 : IDS; Name : String := "") return IDS is
     (if   Is_Const (V1) and then Is_Const (V2)
      then (False, S_Div (V1.Value, V2.Value, Name)) else Var_IDS)
     with Pre  => Present (V1) and then Present (V2),
          Post => Present (S_Div'Result);

   function Build_Min (V1, V2 : IDS; Name : String := "") return IDS
     with Pre  => Present (V1) and then Present (V2),
          Post => Present (Build_Min'Result);

   function Build_Max (V1, V2 : IDS; Name : String := "") return IDS
     with Pre  => Present (V1) and then Present (V2),
          Post => Present (Build_Max'Result);

   function Build_And (V1, V2 : IDS; Name : String := "") return IDS is
     (if   Is_Const (V1) and then Is_Const (V2)
        then (False, Build_And (V1.Value, V2.Value, Name)) else Var_IDS)
     with Pre  => Present (V1) and then Present (V2),
          Post => Present (Build_And'Result);

   function Neg (V : IDS; Name : String := "") return IDS is
     (if   Is_Const (V) then (False, Neg (V.Value, Name)) else Var_IDS)
     with Pre => Present (V), Post => Present (Neg'Result);

   function "+" (LHS, RHS : IDS) return IDS is
     (Add (LHS, RHS));
   function "-" (LHS, RHS : IDS) return IDS is
     (Sub (LHS, RHS));
   function "-" (V : IDS) return IDS is
     (Neg (V));
   function "*" (LHS, RHS : IDS) return IDS is
     (Mul (LHS, RHS));
   function "/" (LHS, RHS : IDS) return IDS is
     (S_Div (LHS, RHS));
   function "<" (LHS, RHS : IDS) return Boolean is
     (Const_Val_ULL (I_Cmp (Int_SLT, LHS, RHS)) = 1);

   function Build_Select
     (V_If, V_Then, V_Else : IDS; Unused_Name : String := "") return IDS
   is
     (if    Is_Const (V_If) and then V_If.Value = Const_True then V_Then
      elsif Is_Const (V_If) then V_Else else Var_IDS)
     with Pre => Present (V_If) and then Present (V_Then)
                 and then Present (V_Else);

   function Extract_Value
     (GT             : GL_Type;
      V              : GL_Value;
      Unused_Idx_Arr : Index_Array;
      Unused_Name    : String := "") return IDS
   is
      (Var_IDS)
     with Pre  => Present (GT) and then Present (V),
          Post => Present (Extract_Value'Result);

   function Convert
     (V              : IDS;
      GT             : GL_Type;
      Float_Truncate : Boolean := False;
      Is_Unchecked   : Boolean := False) return IDS
     with Pre => Present (V) and then Present (GT);

   function Emit_Expr (V : Node_Id; LHS : IDS := No_IDS) return IDS
     with Pre => Present (V), Post => Present (Emit_Expr'Result);

   function Emit_Convert (N : Node_Id; GT : GL_Type) return IDS is
     (Convert (Emit_Expr (N), GT))
     with Pre  => Present (N) and then Present (GT),
          Post => Present (Emit_Convert'Result);

   function Undef (GT : GL_Type) return IDS is
     (Var_IDS)
     with Pre => Present (GT), Post => Present (Undef'Result);

   --  In order to use the generic functions that computing sizing
   --  information to compute a size and position in the form needs for
   --  back-annotation, we need versions of the routines that actually
   --  compute the size that instead track whether it's a constant or
   --  where we need a to use the tree structure that the front-end
   --  provides.  We use the data structure below.

   type BA_Data is record
      Is_None     : Boolean;
      --  True if this is to be treated as an empty entry

      C_Value     : GL_Value;
      --  If a constant, the value of that constant

      T_Value     : Node_Ref;
      --  If dynamic, the tree node reference of the expression
   end record
     with Predicate => Is_None or else Present (C_Value)
                       or else T_Value /= No_Uint;

   type BA_Data_Array is array (Nat range <>) of BA_Data;

   No_BA   : constant BA_Data := (True,  No_GL_Value, No_Uint);

   function No      (V : BA_Data) return Boolean is (V =  No_BA);
   function Present (V : BA_Data) return Boolean is (V /= No_BA);

   --  To simplify the operations below, define access types for unary
   --  and binary operations on GL_Values.

   type Unop_Access is access
     function (V : GL_Value; Name : String := "") return GL_Value;
   type Binop_Access is access
     function (V1, V2 : GL_Value; Name : String := "") return GL_Value;

   function Is_Const  (V : BA_Data) return Boolean is (Present (V.C_Value));

   function Const_Val_ULL (V : BA_Data) return ULL is
     (Get_Const_Int_Value_ULL (V.C_Value))
     with Pre => Is_Const (V);

   function Const_Int (V : BA_Data) return LLI is
     (Get_Const_Int_Value (V.C_Value))
     with Pre => Is_Const (V);

   function Is_Const_0 (V : BA_Data) return Boolean is
     (Is_Const (V) and then Const_Int (V) = 0);
   function Is_Const_1 (V : BA_Data) return Boolean is
     (Is_Const (V) and then Const_Int (V) = 1);

   function Const
     (C : ULL; Sign_Extend : Boolean := False) return BA_Data
   is
     ((False,  Size_Const_Int (C, Sign_Extend), No_Uint))
     with Post => Is_Const (Const'Result);

   function Const (C : Uint) return BA_Data is
     ((False, Size_Const_Int (C), No_Uint))
     with Pre => C /= No_Uint, Post => Is_Const (Const'Result);

   function Const_Int (GT : GL_Type; C : Uint) return BA_Data is
     ((False, Const_Int (GT, C), No_Uint))
     with Pre  => Present (GT) and then C /= No_Uint,
          Post => Is_Const (Const_Int'Result);

   function Annotated_Value (V : BA_Data) return Node_Ref_Or_Val;
   --  Return a Node_Ref corresponding to BA_Data.  This may be either the
   --  T_Value of that data, C_Value converted to a Uint, or No_Uint if
   --  the conversion can't be done.

   function SO_Ref_To_BA (V : SO_Ref) return BA_Data is
     ((if   Is_Static_SO_Ref (V) then Const_Int (Size_GL_Type, V)
       else (False, No_GL_Value, V)));
   --  Likewise, but in the opposite direction

   function Annotated_Object_Size
     (GT : GL_Type; Align : Boolean := False) return Node_Ref_Or_Val
     with Pre => Present (GT);
   --  Given a type that's used for the type of an object, return the
   --  SO_Ref corresponding to the object's size.

   function Unop
     (V    : BA_Data;
      F    : Unop_Access;
      C    : TCode;
      Name : String := "") return BA_Data;
   --  Perform the operation on V defined by F (which is how to modify the
   --  GL_Value) and C (which is how to make a representation tree).;

   function Binop
     (V1, V2 : BA_Data;
      F      : Binop_Access;
      C      : TCode;
      Name   : String := "") return BA_Data;
   --  Likewise, but for a binary operation.

   function Neg (V : BA_Data; Name : String := "") return BA_Data is
     (Unop (V, Neg'Access, Negate_Expr, Name));

   function Get_Type_Size
     (GT         : GL_Type;
      V          : GL_Value := No_GL_Value;
      Max_Size   : Boolean  := False;
      No_Padding : Boolean  := False) return BA_Data
     with Pre => Present (GT);

   function I_Cmp
     (Op       : Int_Predicate_T;
      LHS, RHS : BA_Data;
      Name     : String := "") return BA_Data;

   function Add (V1, V2 : BA_Data; Name : String := "") return BA_Data is
     ((if    Is_Const_0 (V1) then V2
       elsif Is_Const_0 (V2) then V1
       else  Binop (V1, V2, Add'Access, Plus_Expr, Name)));

   function Sub (V1, V2 : BA_Data; Name : String := "") return BA_Data is
     ((if    Is_Const_0 (V2) then V1
       elsif Is_Const_0 (V1) then Neg (V2, Name)
       else  Binop (V1, V2, Sub'Access, Minus_Expr, Name)));

   function Mul (V1, V2 : BA_Data; Name : String := "") return BA_Data is
     ((if    Is_Const_1 (V1) then V2
       elsif Is_Const_1 (V2) then V1
       elsif Is_Const_0 (V1) or else Is_Const_0 (V2) then Const (0)
       else  Binop (V1, V2, Mul'Access, Mult_Expr, Name)));

   function U_Div (V1, V2 : BA_Data; Name : String := "") return BA_Data is
     ((if   Is_Const_1 (V2) then V1
       else Binop (V1, V2, U_Div'Access, Trunc_Div_Expr, Name)));

   function S_Div (V1, V2 : BA_Data; Name : String := "") return BA_Data is
     ((if   Is_Const_1 (V2) then V1
       else Binop (V1, V2, S_Div'Access, Trunc_Div_Expr, Name)));

   function "+" (LHS, RHS : BA_Data) return BA_Data is
     (Add (LHS, RHS));
   function "-" (LHS, RHS : BA_Data) return BA_Data is
     (Sub (LHS, RHS));
   function "-" (V : BA_Data) return BA_Data is
     (Neg (V));
   function "*" (LHS, RHS : BA_Data) return BA_Data is
     (Mul (LHS, RHS));
   function "/" (LHS, RHS : BA_Data) return BA_Data is
     (S_Div (LHS, RHS));
   function "<" (LHS, RHS : BA_Data) return Boolean is
     (Is_Const_1 (I_Cmp (Int_SLT, LHS, RHS)));

   function Build_Min (V1, V2 : BA_Data; Name : String := "") return BA_Data;
   function Build_Max (V1, V2 : BA_Data; Name : String := "") return BA_Data;

   function Build_And (V1, V2 : BA_Data; Name : String := "") return BA_Data is
     ((if   Is_Const_0 (V1) or else Is_Const_0 (V2) then Const (0)
       else Binop (V1, V2, Build_And'Access, Bit_And_Expr, Name)));

   function Truth_Or
         (V1, V2 : BA_Data; Name : String := "") return BA_Data
   is
     ((if   Is_Const_0 (V1) then V2 elsif Is_Const_0 (V2) then V1
       else Binop (V1, V2, Build_Or'Access, Truth_Or_Expr, Name)));

   function Build_Select
     (V_If, V_Then, V_Else : BA_Data; Name : String := "") return BA_Data;

   function Extract_Value
     (GT             : GL_Type;
      V              : GL_Value;
      Unused_Idx_Arr : Index_Array;
      Unused_Name    : String := "") return BA_Data
   is
      (No_BA)
     with Pre => Present (GT) and then Present (V);

   function Convert
     (V              : BA_Data;
      GT             : GL_Type;
      Float_Truncate : Boolean := False;
      Is_Unchecked   : Boolean := False) return BA_Data
     with Pre => Present (GT);

   function Emit_Expr (V : Node_Id; LHS : BA_Data := No_BA) return BA_Data
     with Pre => Present (V);

   function Emit_Convert (N : Node_Id; GT : GL_Type) return BA_Data is
     (Convert (Emit_Expr (N), GT))
     with Pre => Present (GT);

   function Undef (GT : GL_Type) return BA_Data is
     (No_BA)
     with Pre => Present (GT);

   pragma Annotate (Xcov, Exempt_On, "Debug helpers");
   procedure Dump_BA_Data (V : BA_Data)
     with Export, External_Name => "dbad";
   pragma Annotate (Xcov, Exempt_Off, "Debug helpers");

   Disable_LV_Append : Nat := 0;
   --  If nonzero, disable appending expressions to the LValue list.

end GNATLLVM.Types;

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

with Errout;     use Errout;
with Get_Targ;   use Get_Targ;
with Opt;        use Opt;
with Sem_Aux;    use Sem_Aux;
with Sinfo;      use Sinfo;
with Snames;     use Snames;
with Uintp.LLVM; use Uintp.LLVM;

with LLVM.Core; use LLVM.Core;

with GNATLLVM.Arrays;         use GNATLLVM.Arrays;
with GNATLLVM.Arrays.Create;  use GNATLLVM.Arrays.Create;
with GNATLLVM.GLType;         use GNATLLVM.GLType;
with GNATLLVM.Records;        use GNATLLVM.Records;
with GNATLLVM.Records.Create; use GNATLLVM.Records.Create;
with GNATLLVM.Subprograms;    use GNATLLVM.Subprograms;
with GNATLLVM.Utils;          use GNATLLVM.Utils;
with GNATLLVM.Wrapper;        use GNATLLVM.Wrapper;

package body GNATLLVM.Types.Create is

   function Depends_On_Being_Elaborated (TE : Entity_Id) return Boolean
     with Pre => Is_Type_Or_Void (TE);
   --  Return True if TE or any type it depends on is being elaborated

   function Create_Discrete_Type (TE : Entity_Id) return Type_T
     with Pre  => Is_Discrete_Or_Fixed_Point_Type (TE),
          Post => Present (Create_Discrete_Type'Result);
   function Create_Floating_Point_Type (TE : Entity_Id) return Type_T
     with Pre  => Is_Floating_Point_Type (TE),
          Post => Present (Create_Floating_Point_Type'Result);
   function Create_Access_Type
     (TE : Entity_Id; Dummy : out Boolean) return Type_T
     with Pre  => Is_Access_Type (TE),
          Post => Present (Create_Access_Type'Result);
   --  Create an LLVM type for various GNAT types

   ---------------------------------
   -- Depends_On_Being_Elaborated --
   ---------------------------------

   function Depends_On_Being_Elaborated (TE : Entity_Id) return Boolean is
      BT : constant Entity_Id := Full_Base_Type (TE);
      F  : Entity_Id;

   begin
      --  If this is a void type, it doesn't depend on anything.

      if Ekind (TE) = E_Void then
         return False;

      --  This depends on something being elaborated if the type is being
      --  elaborated, its base type depends on something being elaborated,
      --  or this is an array with an aggregate component type that depends
      --  on something being elaborated.

      elsif Is_Being_Elaborated (TE)
        or else (BT /= TE and then Depends_On_Being_Elaborated (BT))
        or else (Is_Array_Type (TE)
                   and then Is_Aggregate_Type (Full_Component_Type (TE))
                   and then (Depends_On_Being_Elaborated
                               (Full_Component_Type (TE))))
      then
         return True;

      --  If this is a record type, it depends on the type of each of
      --  the fields which have aggregate types.

      elsif Is_Record_Type (TE) then
         F := First_Component_Or_Discriminant (TE);
         while Present (F) loop
            exit when Is_Aggregate_Type (Full_Etype (F))
              and then Depends_On_Being_Elaborated (Full_Etype (F));
            Next_Component_Or_Discriminant (F);
         end loop;

         return Present (F);

      else
         --  Otherwise, this doesn't depend on something being elaborated

         return False;
      end if;
   end Depends_On_Being_Elaborated;

   --------------------------
   -- Create_Discrete_Type --
   --------------------------

   function Create_Discrete_Type (TE : Entity_Id) return Type_T is
      Max_Size : constant Uint      := UI_From_Int (Get_Long_Long_Size);
      Size_TE  : constant Entity_Id :=
        (if Has_Biased_Representation (TE) then Full_Base_Type (TE) else TE);
      --  Normally, we want to use an integer representation for a type
      --  that's a different (usually larger) size than it's base type, but
      --  if this is a biased representation, the base type is the primitive
      --  type and we'll use a biased representation as the default
      --  representation of the type.

      Size     : Uint               := Esize (Size_TE);

   begin
      --  It's tempting to use i1 for boolean types, but that causes issues.
      --  First, we'd have to handle booleans with rep clauses specially,
      --  but, perhaps more importantly, LLVM treats a boolean as being true
      --  if it's 1 (interpreted as an 8-bit value) and zero otherwise, but
      --  the more natural interpretaton is that it's false if zero and
      --  true otherwise and this can become visible when using overlays
      --  with 'Address.
      --
      --  So we only use i1 for the internal boolean object (e.g., the result
      --  of a comparison) and for a 1-bit modular type.

      if (Is_Modular_Integer_Type (Size_TE)
            or else (Is_Enumeration_Type (Size_TE) and then Short_Enums))
        and then RM_Size (Size_TE) /= 0
      then
         Size := RM_Size (Size_TE);
      elsif Esize (Size_TE) = 0 then
         Size := UI_From_Int (BPU);
      end if;

      return
        Int_Ty (if Size <= Max_Size then Size else Max_Size);

   end Create_Discrete_Type;

   --------------------------------
   -- Create_Floating_Point_Type --
   --------------------------------

   function Create_Floating_Point_Type (TE : Entity_Id) return Type_T is
      Size : constant Uint := Esize (Full_Base_Type (TE));
      T    : Type_T;
      pragma Assert (UI_Is_In_Int_Range (Size));

   begin
      case Float_Rep (TE) is
         when IEEE_Binary =>
            case UI_To_ULL (Size) is
               when 32 =>
                  T := Float_Type_In_Context (Context);
               when 64 =>
                  T := Double_Type_In_Context (Context);
               when 80 | 96 | 128 =>
                  --  Extended precision; not IEEE_128
                  T := X86_F_P80_Type_In_Context (Context);
               when others =>
                  T := Void_Type;
            end case;

         when AAMP =>
            T := Void_Type;
      end case;

      if T = Void_Type then
         Error_Msg_N ("unsupported floating point type", TE);
      end if;

      return T;
   end Create_Floating_Point_Type;

   ------------------------
   -- Create_Access_Type --
   ------------------------

   function Create_Access_Type
     (TE : Entity_Id; Dummy : out Boolean) return Type_T
   is
      DT : constant Entity_Id       := Full_Designated_Type (TE);
      R  : constant GL_Relationship := Relationship_For_Access_Type (TE);
      GT : GL_Type                  := Default_GL_Type (DT, Create => False);

   begin
      Dummy := False;

      --  If this is a record type, we can get the actual type that will be
      --  used here. If it hasn't been done yet, set it for the record
      --  type, and mark it dummy.

      if Is_Record_Type (DT) then
         if No (GT) then
            GT := New_GT (DT);
            Update_GL_Type (GT, Struct_Create_Named (Context, Get_Name (DT)),
                            True);
         end if;

         Set_Associated_GL_Type (TE, GT);
         return Pointer_Type (Type_Of (GT), 0);

      --  If DT is a subprogram type (since the access type to it is always
      --  the same type), handle this normally, but don't try to record an
      --  associated type.

      elsif Ekind (DT) = E_Subprogram_Type then
         return Type_For_Relationship (DT, R);

      --  If DT doesn't depend on something that's being
      --  elaborated, handle this normally.

      elsif not Depends_On_Being_Elaborated (DT) then
         if No (GT) then
            GT := Default_GL_Type (DT);
         end if;

         Set_Associated_GL_Type (TE, GT);
         return Type_For_Relationship (DT, R);

      --  Otherwise, if DT is currently being elaborated, we have to make a
      --  dummy type that we know will be the same width of an access to
      --  the actual object and we'll convert to the actual type when we
      --  try to access an object of this access type.  The only types
      --  where there's an elaboration that can recurse are record, array,
      --  and access types (though access types whose designated types are
      --  other access types are quite rare).

      else
         Dummy := True;
         if Is_Array_Type (DT) then

            --  For arrays, a pointer to void will work for all but a fat
            --  pointer.  For a fat pointer, use two pointers to void (we
            --  could make an array bound type without actually fully
            --  elaborating the array type, but it's not worth the trouble).

            return (if   R /= Fat_Pointer then Void_Ptr_Type
                    else Build_Struct_Type ((1 => Void_Ptr_Type,
                                             2 => Void_Ptr_Type)));

         elsif Ekind (DT) = E_Subprogram_Type then
            return Void_Ptr_Type;

         else
            --  Access type is the only case left.  We use a void pointer.

            pragma Assert (Is_Access_Type (DT) and then R = Reference);
            return Void_Ptr_Type;
         end if;
      end if;
   end Create_Access_Type;

   -----------------
   -- Create_Type --
   -----------------

   function Create_Type (TE : Entity_Id) return Type_T is
      This_Short_Enum : constant Boolean :=
        Is_Enumeration_Type (TE) and then Short_Enums;
      Dummy           : Boolean          := False;
      Align           : Uint             := No_Uint;
      GT              : GL_Type;
      T               : Type_T;
      TBAA            : Metadata_T;

   begin
      --  Set that we're elaborating the type.  Note that we have to do this
      --  here rather than right before the case statement because we may
      --  have two different types being elaborated that have the same
      --  base type.

      Set_Is_Being_Elaborated (TE, True);

      case Ekind (TE) is
         when E_Void =>
            T := Void_Type;

         when Discrete_Or_Fixed_Point_Kind =>
            T := Create_Discrete_Type (TE);

         when Float_Kind =>
            T := Create_Floating_Point_Type (TE);

         when Access_Kind =>
            T := Create_Access_Type (TE, Dummy);

         when Record_Kind =>
            T := Create_Record_Type (TE);

         when Array_Kind =>
            T := Create_Array_Type (TE);

         when E_Subprogram_Type =>
            T := Create_Subprogram_Type (TE);

         when E_Incomplete_Type =>

            --  This is normally a Taft Amendment type, so return a
            --  dummy type that we can take a pointer to.  But it may also
            --  be an actual type in the case of an error, so use something
            --  that we can take the size an alignment of.

            T := Byte_T;

         when others =>
            Error_Msg_N
              ("unsupported type kind: `" & Ekind (TE)'Image & "`", TE);
            T := Void_Type;
      end case;

      --  Now save the result.  If we don't have a GT already made, make one.

      GT := Default_GL_Type (TE, Create => False);
      if No (GT) then
         GT := New_GT (TE);
      end if;

      --  GT is either a new type (Kind = None) or a
      --  dummy.  If all we were able to return is a dummy type and GT is
      --  also a dummy type, its type should be the same as ours.

      if Dummy and then Is_Dummy_Type (GT) then
         pragma Assert (Type_Of (GT) = T);
         return T;

      --  If we're not a dummy type and GT is a dummy type, we need to
      --  create a new GL_Type for the real type.  This can only happen
      --  for access types.

      elsif not Dummy and then Is_Dummy_Type (GT) then
         pragma Assert (Is_Access_Type (TE));
         GT := New_GT (TE);
      end if;

      --  Set the LLVM type and status of the new GL_Type we made and show
      --  that this type is no longer being elaborated.  If all we have is
      --  a dummy type or if this is a void type, do no more.

      Update_GL_Type (GT, T, Dummy);
      Set_Is_Being_Elaborated (TE, False);
      if Dummy or else Ekind (TE) = E_Void then
         return T;
      end if;

      --  Now make and record the TBAA for the type, if any

      TBAA := Create_TBAA (TE);
      if Present (TBAA) then
         Set_TBAA (TE, TBAA);
      end if;

      --  If this is a packed array implementation type and the original
      --  type is an array, set information about the bounds of the
      --  original array.

      if Is_Packed_Array_Impl_Type (TE) then
         Discard (Create_Array_Type (TE, For_Orig => True));
      end if;

      --  Make a GL_Type corresponding to any specified sizes and
      --  alignments, as well as for biased repesentation.  But don't
      --  do this for void or subprogram types or if we haven't
      --  elaborated Size_Type yet.

      if Ekind (GT) not in E_Void | E_Subprogram_Type
        and then Present (Size_GL_Type)
      then
         --  If there's no alignment specified for this type and it's not a
         --  base type, use the alignment of the base type.  Ignore alignments
         --  for Enumeration types with -fshort-enums.

         if not This_Short_Enum then
            if not Unknown_Alignment (TE) then
               Align := Alignment (TE);
            elsif not Is_Full_Base_Type (TE)
              and then not Unknown_Alignment (Full_Base_Type (TE))
            then
               Align := Alignment (Full_Base_Type (TE));
            end if;
         end if;

         declare
            Size_TE    : constant Entity_Id :=
              (if   Is_Packed_Array_Impl_Type (TE)
               then Original_Array_Type (TE) else TE);
            Size_GT    : constant GL_Value  :=
              (if   Is_Dynamic_Size (GT) then No_GL_Value
               else Get_Type_Size (GT));
            Value_Size : constant Uint      :=
              (if   Unknown_RM_Size (Size_TE) then No_Uint
               else Validate_Size (TE, GT, RM_Size (Size_TE),
                                   For_Type   => True,
                                   Is_RM_Size => True));
            Obj_Size   : constant Uint      :=
              (if   Known_Esize (Size_TE) and then not This_Short_Enum
               then Esize (Size_TE) else RM_Size (Size_TE));
            Size       : constant Uint      :=
              (if   Obj_Size = No_Uint then No_Uint
               else Validate_Size (Size_TE, GT, Obj_Size,
                                   For_Type     => True,
                                   Zero_Allowed =>
                                     Has_Size_Clause (Size_TE)));

         begin
            --  If this is an atomic or VFA type with no alignment specified,
            --  maybe pick an alignment based on the size.

            if Is_Atomic_Or_VFA (TE) then
               if Size /= No_Uint
                 and then (Size = 16 or else Size = 32 or else Size = 64)
               then
                  Align := Size / BPU;
               elsif Present (Size_GT)
                 and then (Size_GT = 16 or else Size_GT = 32
                             or else Size_GT = 64)
               then
                  Align := UI_From_GL_Value (Size_GT) / BPU;
               end if;
            end if;

            --  Ensure the alignment is valid

            Align := Validate_Alignment
              (TE, Align, Get_Type_Alignment (GT, Use_Specified => False));

            --  Now make the GT that we need for this type.  We do this in
            --  two steps so that we can give the proper diagnostics.
            --  First, for composite types and if specified, we use the
            --  RM_Size with no alignment.  Then we make the final GL_Type
            --  from the alignment and specified Esize, if any.

            if Is_Composite_Type (GT) then
               GT := Make_GT_Alternative (GT, TE,
                                          Size     => Value_Size,
                                          For_Type => True);
            end if;

            GT := Make_GT_Alternative (GT, TE,
               Size          => Size,
               Align         => Align,
               For_Type      => True,
               For_Component => False,
               Max_Size      => False,
               Is_Biased     => Has_Biased_Representation (TE));
         end;
      end if;

      --  If this is to be atomic, see if legal

      if Is_Atomic_Or_VFA (TE) then
         Check_OK_For_Atomic_Type (GT, TE);
      end if;

      --  If this type requests a reversed storage order, let the user
      --  know that we don't support that.

      if Ekind (TE) in Record_Kind | Array_Kind
        and then Reverse_Storage_Order (TE) and then not GNAT_Mode
      then
         Error_Msg_NE
           ("reverse storage order for & not supported by 'L'L'V'M", TE, TE);
      end if;

      --  Back-annotate sizes of non-scalar types if there isn't one.
      --  But do back-annotate enums with -fshort-enums.
      --  ???  Don't do anything for access subprogram since this will cause
      --  warnings for UC's in g-thread and g-spipat.

      if not Is_Access_Subprogram_Type (TE)
        and then not (Is_Scalar_Type (TE)
                        and then not (Is_Enumeration_Type (TE)
                                        and then Short_Enums))
      then
         Set_Esize   (TE, Annotated_Object_Size (GT, Do_Align => True));
         Set_RM_Size (TE, Annotated_Value
                        (Get_Type_Size (GT, No_Padding => True)));
      end if;

      Set_Alignment
        (TE, UI_From_ULL
           (Get_Type_Alignment (GT, Use_Specified => False)) / BPU);

      if (Is_Array_Type (TE) or else Is_Modular_Integer_Type (TE))
        and then Present (Original_Array_Type (TE))
        and then Unknown_Alignment (Original_Array_Type (TE))
      then
         Set_Alignment
           (Original_Array_Type (TE),
            UI_From_ULL
              (Get_Type_Alignment (GT, Use_Specified => False)) / BPU);
      end if;

      return Type_Of (GT);
   end Create_Type;

   ----------------------
   -- Copy_Annotations --
   ----------------------

   procedure Copy_Annotations (In_TE, Out_TE : Entity_Id) is
   begin
      --  Copy the annotations we made above (and elsewhere)

      if not Is_Access_Subprogram_Type (Out_TE)
        and then not Is_Scalar_Type (Out_TE)
      then
         if Unknown_Esize (Out_TE) then
            Set_Esize   (Out_TE, Esize (In_TE));
         end if;
         if Unknown_RM_Size (Out_TE) then
            Set_RM_Size (Out_TE, RM_Size (In_TE));

         end if;
      end if;

      if Unknown_Alignment (Out_TE) then
         Set_Alignment (Out_TE, Alignment (In_TE));
      end if;

      if Is_Array_Type (Out_TE) and then Is_Base_Type (Out_TE)
        and then Unknown_Component_Size (Out_TE)
      then
         Set_Component_Size (Out_TE, Component_Size (In_TE));
      end if;
   end Copy_Annotations;

   ------------------------------------------
   -- Annotate_Object_Size_And_Alignmement --
   ------------------------------------------

   procedure Annotate_Object_Size_And_Alignment
     (Def_Ident : Entity_Id; GT : GL_Type) is
   begin
      Set_Esize (Def_Ident, Annotated_Object_Size (GT));
      Set_Alignment
        (Def_Ident,
         UI_From_Int (Get_Type_Alignment (GT, Use_Specified => False)) / BPU);
   end Annotate_Object_Size_And_Alignment;

   -----------------
   -- Create_TBAA --
   -----------------

   function Create_TBAA (TE : Entity_Id) return Metadata_T is
      BT   : constant Entity_Id  := Full_Base_Type (TE);
      TBAA : constant Metadata_T := Get_TBAA (BT);

   begin
      --  If the base type has a TBAA, use it for us.  If it doesn't, it's
      --  probably because this is the base type, in which case, make a
      --  new entry for it.  If it's a type that we don't currently make
      --  TBAA information for, return none.

      if Present (TBAA) then
         return TBAA;
      elsif Is_Scalar_Type (BT) then
         return Create_TBAA_Scalar_Type_Node (MD_Builder, Get_Name (BT),
                                              TBAA_Root);
      else
         return No_Metadata_T;
      end if;
   end Create_TBAA;

   ------------------------
   -- Validate_Alignment --
   ------------------------

   function Validate_Alignment
     (E : Entity_Id; Align : Uint; Current_Align : Nat) return Uint
   is
      TE        : constant Entity_Id :=
        (if Is_Type (E) then E else Full_Etype (E));
      Max_Align : constant Uint      := UI_From_Int (2 ** 29);
      --  This is the maximum permitted alignment, not the maximum default
      --  alignment that's assigned to a type (which is
      --  Get_Maximum_Alignment).

      No_Error  : constant Boolean   :=
        Error_Posted (E) and then not Has_Alignment_Clause (E);
      --  If there's no user-specified alignment clause and we've already
      --  posted an error, don't post another one.

      Clause    : Node_Id            := Alignment_Clause (E);
      N         : Node_Id            := E;
      --  The initial location for an error message is the entity,
      --  but we may override it below if we find a better one.

      New_Align : Nat                := Current_Align;
      --  By default, the new alignment is the same as the old one

   begin
      --  Find a possibly better place to post an alignment error.  If
      --  there's an alignment clause, use its expression.  However, for
      --  the implicit base type of an array type, the alignment clause is
      --  on the first subtype.

      if No (Clause) and then Is_Array_Type (E) and then Is_Full_Base_Type (E)
      then
         Clause := Alignment_Clause (First_Subtype (E));
      elsif No (Clause) and then Is_Record_Type (E)
        and then not Is_Full_Base_Type (E)
      then
         Clause := Alignment_Clause (Full_Base_Type (E));
      end if;

      if Present (Clause) then
         N := Expression (Clause);
      end if;

      --  If the alignment either doesn't fit into an int or is larger than the
      --  maximum allowed, give an error.  Otherwise, we try to use the new
      --  alignment if one is specified.

      if not UI_Is_In_Int_Range (Align) or else Align > Max_Align then
         if not No_Error then
            Error_Msg_NE_Num ("largest supported alignment for& is ^",
                              N, E, Max_Align);
         end if;

         return Max_Align;

      elsif Align /= 0 and then Align /= No_Uint then
         New_Align := UI_To_Int (Align) * BPU;
      end if;

      --  If the alignment is too small, stick with the old alignment and give
      --  an error if required.  We allow scalar types to be under-aligned
      --  as compared to the alignment of the corresponding LLVM type when
      --  defining a type, but not a object.

      if New_Align < Current_Align then
         if not No_Error
           and then (not Is_Type (E) or else Is_Composite_Type (TE))
           and then (No (Clause) or else not From_At_Mod (Clause))
         then
            Error_Msg_NE_Num ("alignment for& must be at least ^",
                              N, E, Current_Align / BPU);
            New_Align := Current_Align;
         end if;
      end if;

      return UI_From_Int (New_Align);
   end Validate_Alignment;

   -------------------
   -- Validate_Size --
   -------------------

   function Validate_Size
     (E             : Entity_Id;
      GT            : GL_Type;
      Size          : Uint;
      For_Type      : Boolean := False;
      For_Component : Boolean := False;
      Zero_Allowed  : Boolean := False;
      Is_RM_Size    : Boolean := False) return Uint
   is
      Val_Clause : constant Node_Id :=
        Get_Attribute_Definition_Clause (E, Attribute_Value_Size);
      Is_Field   : constant Boolean  :=
        Ekind_In (E, E_Component, E_Discriminant);
      Is_Var     : constant Boolean  :=
        not For_Type and then not For_Component and then not Is_Field;
      Error_Node : constant Node_Id  :=
        (if    Is_Field and then Present (Component_Clause (E))
         then  Last_Bit (Component_Clause (E))
         elsif Present (Size_Clause (E)) then Expression (Size_Clause (E))
         else  E);
      Msg_Prefix : constant String   :=
        (if    For_Component then "component size"
         elsif Is_RM_Size and then Present (Val_Clause)
         then  "Value_Size" else "size");
      Size_GT    : GL_Type           := Primitive_GL_Type (GT);
      Is_Dynamic : Boolean           :=
         Is_Dynamic_Size (Size_GT,
                          Max_Size       => Is_Unconstrained_Record (Size_GT),
                          Allow_Overflow => True);
      In_Size    : GL_Value;

   begin
      --  If the size of this subtype is dynamic, try using its base type.
      --  We may have a case where we have a dynamically-constrained
      --  subtype, so we don't know the size, but it can't be larger than
      --  the maximum size of the base type.

      if Is_Dynamic and then not Is_Base_Type (Size_GT) then
         Size_GT    := Primitive_GL_Type (Full_Base_Type (Size_GT));
         Is_Dynamic :=
           Is_Dynamic_Size (Size_GT,
                            Max_Size       =>
                              Is_Unconstrained_Record (Size_GT),
                            Allow_Overflow => True);
      end if;

      --  If no size was specified, if a zero size is specified but isn't
      --  allowed, or if this is a dynamic size (from back-annotation), we're
      --  done.

      if Size = No_Uint or else (Size = 0 and then not Zero_Allowed)
        or else Is_Dynamic_SO_Ref (Size)
      then
         return No_Uint;

      --  The size of objects must always be a multiple of a byte

      elsif Is_Var and then Size mod BPU /= 0 then
         Error_Msg_NE (Msg_Prefix & " for& is not a multiple of Storage_Unit",
                       Error_Node, E);
         return No_Uint;

      --  If this is an integral type or a packed array type, the front-end
      --  has already verified the size, so we need not do it here (which
      --  would mean checking against the bounds).  However, if this is an
      --  aliased object, it may not be smaller than the type of the
      --  object.

      elsif (Is_Discrete_Or_Fixed_Point_Type (GT)
               or else Is_Packed_Array_Impl_Type (GT))
        and then not (Is_Var and Is_Aliased (E))
      then
         return Size;

      --  If the type is of variable size, we can't have a size clause

      elsif Is_Dynamic then
         Error_Msg_NE (Msg_Prefix & " for& too small", Error_Node, E);

         return No_Uint;
      end if;

      --  Otherwise, get the size to compare against

      In_Size :=
        Get_Type_Size (Size_GT, No_GL_Value,
                       Max_Size   => Is_Unconstrained_Record (Size_GT),
                       No_Padding => True);

      --  If this is for a variable, round up the size to the alignment
      --  of the type.

      if Is_Var then
         In_Size := Align_To (In_Size, BPU, Get_Type_Alignment (GT));
      end if;

      --  If this is an access to an unconstrained array, both the size of
      --  a pointer and twice that size is valid.

      if Is_Access_Type (GT)
        and then Is_Unconstrained_Array (Full_Designated_Type (GT))
        and then (Size = Get_Pointer_Size or else Size = Get_Pointer_Size * 2)
      then
         return Size;

      --  If too small, we can't use it

      elsif Size_Const_Int (Size) < In_Size then
         Error_Msg_NE_Num (Msg_Prefix &
                             " for& too small, minimum allowed is ^",
                           Error_Node, E, In_Size);
         return UI_From_GL_Value (In_Size);
      end if;

      --  Otherwise, we're good

      return Size;
   end Validate_Size;

end GNATLLVM.Types.Create;

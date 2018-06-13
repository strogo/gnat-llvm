------------------------------------------------------------------------------
--                                                                          --
--                         GNAT COMPILER COMPONENTS                         --
--                                                                          --
--                           G C C _ W r a p p e r                          --
--                                                                          --
--                                 B o d y                                  --
--                                                                          --
--                     Copyright (C) 1998-2018, AdaCore                     --
--                                                                          --
-- GNAT is free software;  you can  redistribute it  and/or modify it under --
-- terms of the  GNU General Public License as published  by the Free Soft- --
-- ware  Foundation;  either version 3,  or (at your option) any later ver- --
-- sion.  GNAT is distributed in the hope that it will be useful, but WITH- --
-- OUT ANY WARRANTY;  without even the  implied warranty of MERCHANTABILITY --
-- or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License --
-- for  more details.  You should have  received  a copy of the GNU General --
-- Public License  distributed with GNAT; see file COPYING3.  If not, go to --
-- http://www.gnu.org/licenses for a complete copy of the license.          --
--                                                                          --
------------------------------------------------------------------------------

--  Simple GCC wrapper to provide a GCC-like interface for tools such as
--  ASIS-based tools (or automated tests) which expect xxx-gcc as the Ada
--  driver.

with Ada.Text_IO;       use Ada.Text_IO;
with Ada.Command_Line;  use Ada.Command_Line;
with Ada.Strings.Fixed; use Ada.Strings.Fixed;
with GNAT.OS_Lib;       use GNAT.OS_Lib;
with Gnatvsn;

procedure GCC_Wrapper is

   function Base_Name (S : String) return String;

   function Get_Target return String;

   function Base_Name (S : String) return String is
      First : Natural := S'First;
      Last  : Natural := S'Last;
   begin
      if Index (S, ".exe") in S'Range then
         Last := Index (S, ".exe") - 1;
      end if;

      for J in reverse S'Range loop
         if S (J) = '/'
           or else S (J) = '\'
         then
            First := J + 1;
            exit;
         end if;
      end loop;

      return S (First .. Last);
   end Base_Name;

   function Get_Target return String is
      Base : constant String := Base_Name (Command_Name);
      Last : constant Natural := Index (Base, "-") - 1;
   begin
      return Base (Base'First .. Last);
   end Get_Target;

   GCC       : constant String := Command_Name;
   Args      : Argument_List (1 .. Argument_Count);
   Arg_Count : Natural := 0;
   Status    : Boolean;
   Last      : Natural;
   Compile   : Boolean := False;
   Verbose   : Boolean := False;

   procedure Spawn (S : String; Args : Argument_List; Status : out Boolean);
   --  Call GNAT.OS_Lib.Spawn and take Verbose into account

   -----------
   -- Spawn --
   -----------

   procedure Spawn (S : String; Args : Argument_List; Status : out Boolean) is
   begin
      if Verbose then
         Put (S);

         for J in Args'Range loop
            Put (" " & Args (J).all);
         end loop;

         New_Line;
      end if;

      GNAT.OS_Lib.Spawn (S, Args, Status);
   end Spawn;

begin
   if Args'Last = 1 then
      declare
         Arg : constant String := Argument (1);
      begin
         if Arg = "-v" then
            Put_Line ("Target: " & Get_Target);
            Put_Line (Base_Name (GCC) & " version " &
                        Gnatvsn.Library_Version & " for GNAT " &
                        Gnatvsn.Gnat_Version_String);
            OS_Exit (0);

         elsif Arg = "-dumpversion" then
            Put_Line (Gnatvsn.Gnat_Static_Version_String);
            OS_Exit (0);

         elsif Arg = "-dumpmachine" then
            Put_Line (Get_Target);
            OS_Exit (0);
         end if;
      end;
   end if;

   for J in Args'Range loop
      declare
         Arg  : constant String := Argument (J);
         Skip : Boolean := False;
      begin
         if Arg = "-c" or else Arg = "-S" then
            Compile := True;

         elsif Arg = "-v" then
            Verbose := True;
            Skip := True;
         end if;

         if not Skip then
            Arg_Count := Arg_Count + 1;
            Args (Arg_Count) := new String'(Arg);
         end if;
      end;
   end loop;

   if GCC'Length >= 3
     and then GCC (GCC'Last - 2 .. GCC'Last) = "gcc"
   then
      Last := GCC'Last - 3;

   elsif GCC'Length >= 7
     and then GCC (GCC'Last - 6 .. GCC'Last) = "gcc.exe"
   then
      Last := GCC'Last - 7;

   else
      Put_Line ("unexpected program name: " & GCC & ", exiting.");
      Set_Exit_Status (Failure);
      return;
   end if;

   if Compile then
      declare
         Compiler : constant String := GCC (GCC'First .. Last) & "gnat1";
         S        : String_Access;
      begin
         S := Locate_Exec_On_Path (Compiler);

         if S = null then
            Put_Line (Compiler & " not found");
            Set_Exit_Status (Failure);
            return;
         end if;

         --  ??? delete previous .o file

         Spawn (S.all, Args (1 .. Arg_Count), Status);
         Free (S);
      end;
   else
      declare
         Linker : constant String := GCC (GCC'First .. Last) & "ld";
         S      : String_Access;
      begin
         S := Locate_Exec_On_Path (Linker);

         if S = null then
            --  If llvm-ld is not found, default to "clang" for now
            S := Locate_Exec_On_Path ("clang");
         end if;

         if S = null then
            Put_Line (Linker & " not found");
            Set_Exit_Status (Failure);
            return;
         end if;

         Spawn (S.all, Args (1 .. Arg_Count), Status);
         Free (S);
      end;
   end if;

   if Status then
      Set_Exit_Status (Success);
   else
      Set_Exit_Status (Failure);
   end if;
end GCC_Wrapper;

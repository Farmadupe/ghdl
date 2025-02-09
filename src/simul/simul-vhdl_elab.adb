--  Elaboration for VHDL simulation
--  Copyright (C) 2022 Tristan Gingold
--
--  This file is part of GHDL.
--
--  This program is free software: you can redistribute it and/or modify
--  it under the terms of the GNU General Public License as published by
--  the Free Software Foundation, either version 2 of the License, or
--  (at your option) any later version.
--
--  This program is distributed in the hope that it will be useful,
--  but WITHOUT ANY WARRANTY; without even the implied warranty of
--  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
--  GNU General Public License for more details.
--
--  You should have received a copy of the GNU General Public License
--  along with this program.  If not, see <gnu.org/licenses>.

with Vhdl.Errors; use Vhdl.Errors;
with Vhdl.Utils; use Vhdl.Utils;
with Vhdl.Canon;

with Synth.Vhdl_Stmts;
with Trans_Analyzes;
with Elab.Vhdl_Decls;

with Simul.Vhdl_Debug;

package body Simul.Vhdl_Elab is
   procedure Gather_Processes_1 (Inst : Synth_Instance_Acc);

   procedure Convert_Type_Width (T : Type_Acc) is
   begin
      if T.Wkind = Wkind_Sim then
         return;
      end if;
      case T.Kind is
         when Type_Bit
           | Type_Logic
           | Type_Discrete
           | Type_Float =>
            T.W := 1;
            T.Wkind := Wkind_Sim;
         when Type_Vector
           | Type_Array =>
            Convert_Type_Width (T.Arr_El);
            T.W := T.Abound.Len * T.Arr_El.W;
            T.Wkind := Wkind_Sim;
         when Type_Record =>
            T.W := 0;
            for I in T.Rec.E'Range loop
               T.Rec.E (I).Offs.Net_Off := T.W;
               Convert_Type_Width (T.Rec.E (I).Typ);
               T.W := T.W + T.Rec.E (I).Typ.W;
            end loop;
            T.Wkind := Wkind_Sim;
         when others =>
            raise Internal_Error;
      end case;
   end Convert_Type_Width;

   procedure Gather_Signal (Proto_E : Signal_Entry)
   is
      Val : constant Valtyp := Get_Value (Proto_E.Inst, Proto_E.Decl);
      E : Signal_Entry;
   begin
      E := Proto_E;
      E.Typ := Val.Typ;
      Convert_Type_Width (E.Typ);
      Current_Pool := Global_Pool'Access;
      E.Val := Alloc_Memory (E.Typ);
      Current_Pool := Expr_Pool'Access;
      if Val.Val.Init /= null then
         Copy_Memory (E.Val, Val.Val.Init.Mem, E.Typ.Sz);
      else
         Write_Value_Default (E.Val, E.Typ);
      end if;
      E.Sig := null;

      pragma Assert (E.Kind /= Mode_End);
      pragma Assert (Signals_Table.Table (Val.Val.S).Kind = Mode_End);
      Signals_Table.Table (Val.Val.S) := E;
   end Gather_Signal;

   procedure Gather_Quantity (Inst : Synth_Instance_Acc; Decl : Node)
   is
      Val : constant Valtyp := Get_Value (Inst, Decl);
   begin
      Convert_Type_Width (Val.Typ);
      pragma Assert (Val.Val.Q = No_Quantity_Index);
      Quantity_Table.Append ((Decl, Inst, Val.Typ, null, No_Scalar_Quantity));
      Val.Val.Q := Quantity_Table.Last;
   end Gather_Quantity;

   procedure Gather_Terminal (Inst : Synth_Instance_Acc; Decl : Node)
   is
      Val : constant Valtyp := Get_Value (Inst, Decl);
      Def : constant Node := Get_Nature (Decl);
      Across_Typ : Type_Acc;
      Through_Typ : Type_Acc;
   begin
      Across_Typ := Get_Subtype_Object (Inst, Get_Across_Type (Def));
      Through_Typ := Get_Subtype_Object (Inst, Get_Through_Type (Def));
      pragma Assert (Val.Val.T = No_Terminal_Index);
      Terminal_Table.Append ((Decl, Inst, Across_Typ, Through_Typ, null));
      Val.Val.T := Terminal_Table.Last;
   end Gather_Terminal;

   procedure Gather_Processes_Decl (Inst : Synth_Instance_Acc; Decl : Node) is
   begin
      case Get_Kind (Decl) is
         when Iir_Kind_Interface_Signal_Declaration =>
            --  Driver.
            case Get_Mode (Decl) is
               when Iir_Unknown_Mode =>
                  raise Internal_Error;
               when Iir_Linkage_Mode =>
                  Gather_Signal ((Mode_Linkage, Decl, Inst, null, null, null,
                                  No_Sensitivity_Index, No_Signal_Index,
                                  No_Driver_Index, No_Connect_Index));
               when Iir_Buffer_Mode =>
                  Gather_Signal ((Mode_Buffer, Decl, Inst, null, null, null,
                                  No_Sensitivity_Index, No_Signal_Index,
                                  No_Driver_Index, No_Connect_Index));
               when Iir_Out_Mode =>
                  Gather_Signal ((Mode_Out, Decl, Inst, null, null, null,
                                  No_Sensitivity_Index, No_Signal_Index,
                                  No_Driver_Index, No_Connect_Index));
               when Iir_Inout_Mode =>
                  Gather_Signal ((Mode_Inout, Decl, Inst, null, null, null,
                                  No_Sensitivity_Index, No_Signal_Index,
                                  No_Driver_Index, No_Connect_Index));
               when Iir_In_Mode =>
                  Gather_Signal ((Mode_In, Decl, Inst, null, null, null,
                                  No_Sensitivity_Index, No_Signal_Index,
                                  No_Driver_Index, No_Connect_Index));
            end case;
         when Iir_Kind_Signal_Declaration =>
            Gather_Signal ((Mode_Signal, Decl, Inst, null, null, null,
                            No_Sensitivity_Index, No_Signal_Index,
                            No_Driver_Index, No_Connect_Index));
         when Iir_Kind_Configuration_Specification =>
            null;
         when Iir_Kind_Free_Quantity_Declaration
           | Iir_Kinds_Branch_Quantity_Declaration
           | Iir_Kind_Dot_Attribute =>
            Gather_Quantity (Inst, Decl);
         when Iir_Kind_Terminal_Declaration =>
            Gather_Terminal (Inst, Decl);
         when Iir_Kind_Nature_Declaration =>
            declare
               Def : constant Node := Get_Nature (Decl);
               Across_Typ : constant Type_Acc :=
                 Get_Subtype_Object (Inst, Get_Across_Type (Def));
               Through_Typ : constant Type_Acc :=
                 Get_Subtype_Object (Inst, Get_Through_Type (Def));
            begin
               Convert_Type_Width (Across_Typ);
               Convert_Type_Width (Through_Typ);
            end;
         when Iir_Kind_Attribute_Implicit_Declaration =>
            declare
               Sig : Node;
            begin
               Sig := Get_Attribute_Implicit_Chain (Decl);
               while Sig /= Null_Node loop
                  Gather_Processes_Decl (Inst, Sig);
                  Sig := Get_Attr_Chain (Sig);
               end loop;
            end;
         when Iir_Kind_Above_Attribute =>
            Gather_Signal ((Mode_Above, Decl, Inst, null, null, null,
                            No_Sensitivity_Index, No_Signal_Index));
         when Iir_Kind_Constant_Declaration
           | Iir_Kind_Variable_Declaration
           | Iir_Kind_Object_Alias_Declaration
           | Iir_Kind_Non_Object_Alias_Declaration
           | Iir_Kind_Attribute_Declaration
           | Iir_Kind_Attribute_Specification
           | Iir_Kind_Type_Declaration
           | Iir_Kind_Anonymous_Type_Declaration
           | Iir_Kind_Subtype_Declaration
           | Iir_Kind_Function_Declaration
           | Iir_Kind_Procedure_Declaration
           | Iir_Kind_Function_Body
           | Iir_Kind_Procedure_Body
           | Iir_Kind_Component_Declaration =>
            null;
         when others =>
            Error_Kind ("gather_processes_decl", Decl);
      end case;
   end Gather_Processes_Decl;

   procedure Gather_Processes_Decls
     (Inst : Synth_Instance_Acc; Decls : Node)
   is
      Decl : Node;
   begin
      Decl := Decls;
      while Decl /= Null_Node loop
         Gather_Processes_Decl (Inst, Decl);
         Decl := Get_Chain (Decl);
      end loop;
   end Gather_Processes_Decls;

   procedure Add_Process_Driver (Proc_Idx : Process_Index_Type;
                                 Sig : Signal_Index_Type;
                                 Off : Value_Offsets;
                                 Typ : Type_Acc) is
   begin
      Drivers_Table.Append
        ((Sig => Sig,
          Off => Off,
          Typ => Typ,
          Prev_Sig => Signals_Table.Table (Sig).Drivers,

          Proc => Proc_Idx,
          Prev_Proc => Processes_Table.Table (Proc_Idx).Drivers));

      Signals_Table.Table (Sig).Drivers := Drivers_Table.Last;
      Processes_Table.Table (Proc_Idx).Drivers := Drivers_Table.Last;
   end Add_Process_Driver;

   procedure Gather_Process_Drivers
     (Inst : Synth_Instance_Acc; Proc : Node; Proc_Idx : Process_Index_Type)
   is
      use Synth.Vhdl_Stmts;
      Driver_List: Iir_List;
      It : List_Iterator;
      Sig : Node;
      Base_Vt : Valtyp;
      Base : Signal_Index_Type;
      Typ : Type_Acc;
      Off : Value_Offsets;
      Dyn : Dyn_Name;
   begin
      Driver_List := Trans_Analyzes.Extract_Drivers (Proc);
      It := List_Iterate_Safe (Driver_List);
      while Is_Valid (It) loop
         Sig := Get_Element (It);
         exit when Sig = Null_Node;
         Synth_Assignment_Prefix (Inst, Sig, Base_Vt, Typ, Off, Dyn);
         pragma Assert (Dyn = No_Dyn_Name);
         Base := Base_Vt.Val.S;

         Add_Process_Driver (Proc_Idx, Base, Off, Typ);

         Next (It);
      end loop;
      Trans_Analyzes.Free_Drivers_List (Driver_List);
   end Gather_Process_Drivers;

   procedure Gather_Sensitivity (Inst : Synth_Instance_Acc;
                                 Proc_Idx : Process_Index_Type;
                                 List : Iir_List)
   is
      use Synth.Vhdl_Stmts;
      It : List_Iterator;
      Sig : Node;
      Base_Vt : Valtyp;
      Base : Signal_Index_Type;
      Typ : Type_Acc;
      Off : Value_Offsets;
      Dyn : Dyn_Name;
   begin
      It := List_Iterate_Safe (List);
      while Is_Valid (It) loop
         Sig := Get_Element (It);
         exit when Sig = Null_Node;
         Synth_Assignment_Prefix (Inst, Sig, Base_Vt, Typ, Off, Dyn);
         pragma Assert (Dyn = No_Dyn_Name);
         Base := Base_Vt.Val.S;

         Sensitivity_Table.Append
           ((Sig => Base,
             Off => Off,
             Typ => Typ,
             Prev_Sig => Signals_Table.Table (Base).Sensitivity,

             Proc => Proc_Idx,
             Prev_Proc => Processes_Table.Table (Proc_Idx).Sensitivity));

         Signals_Table.Table (Base).Sensitivity := Sensitivity_Table.Last;
         Processes_Table.Table (Proc_Idx).Sensitivity :=
           Sensitivity_Table.Last;

         Next (It);
      end loop;
   end Gather_Sensitivity;

   procedure Gather_Process_Sensitivity
     (Inst : Synth_Instance_Acc; Proc : Node; Proc_Idx : Process_Index_Type)
   is
      List : Iir_List;
   begin
      case Get_Kind (Proc) is
         when Iir_Kind_Process_Statement =>
            --  No sensitivity list.
            --  TODO: extract potential list from wait statements ?
            return;
         when Iir_Kind_Concurrent_Simple_Signal_Assignment =>
            List := Create_Iir_List;
            Vhdl.Canon.Canon_Extract_Sensitivity_Simple_Signal_Assignment
              (Proc, List);
         when Iir_Kind_Concurrent_Conditional_Signal_Assignment =>
            List := Create_Iir_List;
            Vhdl.Canon.Canon_Extract_Sensitivity_Conditional_Signal_Assignment
              (Proc, List);
         when Iir_Kind_Concurrent_Selected_Signal_Assignment =>
            List := Create_Iir_List;
            Vhdl.Canon.Canon_Extract_Sensitivity_Selected_Signal_Assignment
              (Proc, List);
         when Iir_Kind_Concurrent_Assertion_Statement =>
            List := Create_Iir_List;
            Vhdl.Canon.Canon_Extract_Sensitivity_Assertion_Statement
              (Proc, List);
         when Iir_Kind_Concurrent_Procedure_Call_Statement =>
            List := Create_Iir_List;
            Vhdl.Canon.Canon_Extract_Sensitivity_Procedure_Call
              (Get_Procedure_Call (Proc), List);
         when Iir_Kind_Sensitized_Process_Statement =>
            List := Get_Sensitivity_List (Proc);
            if List = Iir_List_All then
               List := Vhdl.Canon.Canon_Extract_Sensitivity_Process (Proc);
            else
               Gather_Sensitivity (Inst, Proc_Idx, List);
               return;
            end if;
         when Iir_Kind_Psl_Assert_Directive =>
            List := Get_PSL_Clock_Sensitivity (Proc);
            Gather_Sensitivity (Inst, Proc_Idx, List);
            return;
         when Iir_Kind_Concurrent_Break_Statement =>
            List := Get_Sensitivity_List (Proc);
            if List /= Null_Iir_List then
               Gather_Sensitivity (Inst, Proc_Idx, List);
               return;
            else
               List := Create_Iir_List;
               Vhdl.Canon.Canon_Extract_Sensitivity_Break_Statement
                 (Proc, List);
            end if;
         when others =>
            Error_Kind ("gather_process_sensitivity", Proc);
      end case;
      Gather_Sensitivity (Inst, Proc_Idx, List);
      Destroy_Iir_List (List);
   end Gather_Process_Sensitivity;

   procedure Gather_Connections (Port_Inst : Synth_Instance_Acc;
                                 Ports : Node;
                                 Assoc_Inst : Synth_Instance_Acc;
                                 Assocs : Node)
   is
      use Synth.Vhdl_Stmts;
      Assoc_Inter : Node;
      Assoc : Node;
      Inter : Node;
      Formal_Base : Valtyp;
      Actual_Base : Valtyp;
      Formal_Sig : Signal_Index_Type;
      Actual_Sig : Signal_Index_Type;
      Typ : Type_Acc;
      Off : Value_Offsets;
      Dyn : Dyn_Name;
      Conn : Connect_Entry;
      List : Iir_List;
   begin
      Assoc := Assocs;
      Assoc_Inter := Ports;
      while Is_Valid (Assoc) loop
         case Get_Kind (Assoc) is
            when Iir_Kind_Association_Element_By_Name =>
               Inter := Get_Association_Interface (Assoc, Assoc_Inter);
               Synth_Assignment_Prefix
                 (Port_Inst, Inter, Formal_Base, Typ, Off, Dyn);
               pragma Assert (Dyn = No_Dyn_Name);
               Formal_Sig := Formal_Base.Val.S;
               Conn.Formal_Base := Formal_Sig;
               Conn.Formal_Offs := Off;
               Conn.Formal_Type := Typ;
               Conn.Formal_Link := Signals_Table.Table (Formal_Sig).Connect;

               Synth_Assignment_Prefix
                 (Assoc_Inst, Get_Actual (Assoc), Actual_Base, Typ, Off, Dyn);
               pragma Assert (Dyn = No_Dyn_Name);
               Actual_Sig := Actual_Base.Val.S;
               Conn.Actual_Base := Actual_Sig;
               Conn.Actual_Offs := Off;
               Conn.Actual_Type := Typ;
               Conn.Actual_Link := Signals_Table.Table (Actual_Sig).Connect;

               Conn.Assoc := Assoc;
               Conn.Assoc_Inst := Assoc_Inst;

               --  LRM08 6.4.2.3 Signal declarations
               --  [...], each source is either a driver or an OUT, INOUT,
               --  BUFFER, or LINKAGE port [...]
               case Get_Mode (Inter) is
                  when Iir_In_Mode =>
                     Conn.Drive_Formal := True;
                     Conn.Drive_Actual := False;
                  when Iir_Out_Mode
                    | Iir_Buffer_Mode =>
                     Conn.Drive_Formal := False;
                     Conn.Drive_Actual := True;
                  when Iir_Inout_Mode
                    | Iir_Linkage_Mode =>
                     Conn.Drive_Formal := True;
                     Conn.Drive_Actual := True;
                  when Iir_Unknown_Mode =>
                     raise Internal_Error;
               end case;

               Connect_Table.Append (Conn);

               Signals_Table.Table (Formal_Sig).Connect := Connect_Table.Last;
               Signals_Table.Table (Actual_Sig).Connect := Connect_Table.Last;

               --  Collapse
               if Get_Collapse_Signal_Flag (Assoc) then
                  pragma Assert (Conn.Formal_Offs.Mem_Off = 0);
                  pragma Assert (Conn.Actual_Offs.Mem_Off = 0);
                  pragma Assert (Actual_Base.Typ.W = Typ.W);
                  pragma Assert (Formal_Base.Typ.W = Typ.W);
                  pragma Assert (Signals_Table.Table (Formal_Sig).Collapsed_By
                                   = No_Signal_Index);
                  pragma Assert (Formal_Sig > Actual_Sig);
                  Signals_Table.Table (Formal_Sig).Collapsed_By := Actual_Sig;
               else
                  --  TODO: handle non-collapsed signals in simul.
                  raise Internal_Error;
               end if;
            when Iir_Kind_Association_Element_Open
              | Iir_Kind_Association_Element_By_Individual =>
               null;
            when Iir_Kind_Association_Element_By_Expression =>
               if Get_Expr_Staticness (Get_Actual (Assoc)) < Globally then
                  Inter := Get_Association_Interface (Assoc, Assoc_Inter);
                  Synth_Assignment_Prefix
                    (Port_Inst, Inter, Formal_Base, Typ, Off, Dyn);
                  pragma Assert (Dyn = No_Dyn_Name);
                  Formal_Sig := Formal_Base.Val.S;
                  Conn.Formal_Base := Formal_Sig;
                  Conn.Formal_Offs := Off;
                  Conn.Formal_Type := Typ;
                  Conn.Formal_Link := Signals_Table.Table (Formal_Sig).Connect;

                  Conn.Actual_Base := No_Signal_Index;
                  Conn.Actual_Offs := No_Value_Offsets;
                  Conn.Actual_Type := null;
                  Conn.Actual_Link := No_Connect_Index;

                  Conn.Assoc := Assoc;
                  Conn.Assoc_Inst := Assoc_Inst;

                  --  Always an IN interface.
                  Conn.Drive_Formal := True;
                  Conn.Drive_Actual := False;

                  Connect_Table.Append (Conn);

                  Signals_Table.Table (Formal_Sig).Connect :=
                    Connect_Table.Last;

                  Processes_Table.Append
                    ((Proc => Assoc,
                      Inst => Assoc_Inst,
                      Drivers => No_Driver_Index,
                      Sensitivity => No_Sensitivity_Index));

                  Add_Process_Driver
                    (Processes_Table.Last, Formal_Sig, Off, Typ);

                  List := Create_Iir_List;
                  Vhdl.Canon.Canon_Extract_Sensitivity_Expression
                    (Get_Actual (Assoc), List, False);
                  Gather_Sensitivity (Assoc_Inst, Processes_Table.Last, List);
                  Destroy_Iir_List (List);
               else
                  raise Internal_Error;
               end if;
            when others =>
               Error_Kind ("gather_connections", Assoc);
         end case;
         Next_Association_Interface (Assoc, Assoc_Inter);
      end loop;
   end Gather_Connections;

   procedure Gather_Connections_Instantiation_Statement
     (Inst : Synth_Instance_Acc; Stmt : Node; Sub_Inst : Synth_Instance_Acc)
   is
      Sub_Scope : constant Node := Get_Source_Scope (Sub_Inst);
      Comp_Inst : Synth_Instance_Acc;
      Arch : Node;
      Ent : Node;
      Config : Node;
      Bind : Node;
   begin
      if Get_Kind (Sub_Scope) = Iir_Kind_Component_Declaration then
         --  Connections with the components.
         Gather_Connections (Sub_Inst, Get_Port_Chain (Sub_Scope),
                             Inst, Get_Port_Map_Aspect_Chain (Stmt));
         --  Connections with the entity
         Comp_Inst := Get_Component_Instance (Sub_Inst);
         if Comp_Inst = null then
            --  Unbounded.
            return;
         end if;
         Arch := Get_Source_Scope (Comp_Inst);
         Ent := Get_Entity (Arch);
         Config := Get_Instance_Config (Sub_Inst);
         Bind := Get_Binding_Indication (Config);
         --  Connections of the entity with the component.
         Gather_Connections (Comp_Inst, Get_Port_Chain (Ent),
                             Sub_Inst, Get_Port_Map_Aspect_Chain (Bind));
      else
         pragma Assert (Get_Kind (Sub_Scope) = Iir_Kind_Architecture_Body);
         Gather_Connections
           (Sub_Inst, Get_Port_Chain (Get_Entity (Sub_Scope)),
            Inst, Get_Port_Map_Aspect_Chain (Stmt));
      end if;
   end Gather_Connections_Instantiation_Statement;

   procedure Gather_Processes_Stmt
     (Inst : Synth_Instance_Acc; Stmt : Node) is
   begin
      case Get_Kind (Stmt) is
         when Iir_Kind_Component_Instantiation_Statement =>
            declare
               Sub_Inst : constant Synth_Instance_Acc :=
                 Get_Sub_Instance (Inst, Stmt);
            begin
               Gather_Processes_1 (Sub_Inst);
               Gather_Connections_Instantiation_Statement
                 (Inst, Stmt, Sub_Inst);
            end;
         when Iir_Kind_If_Generate_Statement =>
            declare
               Sub : constant Synth_Instance_Acc :=
                 Get_Sub_Instance (Inst, Stmt);
            begin
               if Sub /= null then
                  Gather_Processes_1 (Sub);
               end if;
            end;
         when Iir_Kind_For_Generate_Statement =>
            declare
               It : constant Node := Get_Parameter_Specification (Stmt);
               It_Rng : Type_Acc;
               It_Len : Natural;
               Gen_Inst : Synth_Instance_Acc;
            begin
               It_Rng := Get_Subtype_Object (Inst, Get_Type (It));
               It_Len := Natural (Get_Range_Length (It_Rng.Drange));
               Gen_Inst := Get_Sub_Instance (Inst, Stmt);
               for I in 1 .. It_Len loop
                  Gather_Processes_1
                    (Get_Generate_Sub_Instance (Gen_Inst, I));
               end loop;
            end;
         when Iir_Kind_Block_Statement =>
            declare
               Sub : constant Synth_Instance_Acc :=
                 Get_Sub_Instance (Inst, Stmt);
            begin
               Gather_Processes_1 (Sub);
            end;
         when Iir_Kinds_Concurrent_Signal_Assignment
           | Iir_Kind_Concurrent_Assertion_Statement
           | Iir_Kind_Concurrent_Procedure_Call_Statement
           | Iir_Kinds_Process_Statement =>
            Processes_Table.Append ((Proc => Stmt,
                                     Inst => Inst,
                                     Drivers => No_Driver_Index,
                                     Sensitivity => No_Sensitivity_Index));
            Gather_Process_Drivers (Inst, Stmt, Processes_Table.Last);
            Gather_Process_Sensitivity (Inst, Stmt, Processes_Table.Last);
         when Iir_Kind_Psl_Default_Clock =>
            null;
         when Iir_Kind_Psl_Assert_Directive
           | Iir_Kind_Concurrent_Break_Statement =>
            Processes_Table.Append ((Proc => Stmt,
                                     Inst => Inst,
                                     Drivers => No_Driver_Index,
                                     Sensitivity => No_Sensitivity_Index));
            Gather_Process_Sensitivity (Inst, Stmt, Processes_Table.Last);
         when Iir_Kind_Simple_Simultaneous_Statement =>
            Simultaneous_Table.Append ((Stmt => Stmt, Inst => Inst));
         when others =>
            Vhdl.Errors.Error_Kind ("gather_processes_stmt", Stmt);
      end case;
   end Gather_Processes_Stmt;

   procedure Gather_Processes_Stmts (Inst : Synth_Instance_Acc; Stmts : Node)
   is
      Stmt : Node;
   begin
      Stmt := Stmts;
      while Stmt /= Null_Node loop
         Gather_Processes_Stmt (Inst, Stmt);
         Stmt := Get_Chain (Stmt);
      end loop;
   end Gather_Processes_Stmts;

   procedure Gather_Processes_1 (Inst : Synth_Instance_Acc)
   is
      N : constant Node := Get_Source_Scope (Inst);
   begin
      case Get_Kind (N) is
         when Iir_Kind_Architecture_Body =>
            declare
               Ent : constant Node := Get_Entity (N);
            begin
               Gather_Processes_Decls
                 (Inst, Get_Port_Chain (Ent));
               Gather_Processes_Decls
                 (Inst, Get_Declaration_Chain (Ent));
               Gather_Processes_Stmts
                 (Inst, Get_Concurrent_Statement_Chain (Ent));
               Gather_Processes_Decls
                 (Inst, Get_Declaration_Chain (N));
               Gather_Processes_Stmts
                 (Inst, Get_Concurrent_Statement_Chain (N));
            end;
         when Iir_Kind_Component_Declaration =>
            declare
               Comp_Inst : constant Synth_Instance_Acc :=
                 Get_Component_Instance (Inst);
            begin
               Gather_Processes_Decls (Inst, Get_Port_Chain (N));
               if Comp_Inst /= null then
                  Gather_Processes_1 (Comp_Inst);
               end if;
            end;
         when Iir_Kind_Generate_Statement_Body
           | Iir_Kind_Block_Statement =>
            Gather_Processes_Decls
              (Inst, Get_Declaration_Chain (N));
            Gather_Processes_Stmts
              (Inst, Get_Concurrent_Statement_Chain (N));
         when Iir_Kind_Package_Declaration =>
            Gather_Processes_Decls
              (Inst, Get_Declaration_Chain (N));
         when others =>
            Vhdl.Errors.Error_Kind ("gater_processes_1", N);
      end case;
   end Gather_Processes_1;

   procedure Gather_Processes (Top : Synth_Instance_Acc) is
   begin
      Processes_Table.Init;
      Signals_Table.Init;
      Drivers_Table.Init;

      Simul.Vhdl_Debug.Init;

      Signals_Table.Set_Last (Get_Nbr_Signal);
      for I in Signals_Table.First .. Signals_Table.Last loop
         Signals_Table.Table (I) :=
           (Mode_End, Null_Node, null, null, null, null,
            No_Sensitivity_Index, No_Signal_Index);
      end loop;

      --  Gather declarations of top-level packages.
      declare
         It : Iterator_Top_Level_Type;
         Inst : Synth_Instance_Acc;
      begin
         It := Iterator_Top_Level_Init;
         loop
            Iterate_Top_Level (It, Inst);
            exit when Inst = null;
            pragma Assert (Inst /= Top);
            Gather_Processes_1 (Inst);
         end loop;
      end;

      Gather_Processes_1 (Top);

      --  For the debugger.
      Top_Instance := Top;
   end Gather_Processes;

   procedure Elab_Processes
   is
      Proc : Node;
      Proc_Inst : Synth_Instance_Acc;
   begin
      for I in Processes_Table.First .. Processes_Table.Last loop
         Proc := Processes_Table.Table (I).Proc;
         if Get_Kind (Proc) in Iir_Kinds_Process_Statement then
            Proc_Inst := Make_Elab_Instance (Processes_Table.Table (I).Inst,
                                             Proc, Null_Node);
            Processes_Table.Table (I).Inst := Proc_Inst;
            Elab.Vhdl_Decls.Elab_Declarations
              (Proc_Inst, Get_Declaration_Chain (Proc), True);
         end if;
      end loop;
   end Elab_Processes;

   procedure Elab_Drivers is
   begin
      null;
   end Elab_Drivers;
end Simul.Vhdl_Elab;

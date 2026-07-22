----------------------------------------------------------------------------------
-- GENERATED FILE — do not hand-edit (BOUNDARY-V2.md one-table rule).
-- Regenerate:  python3 M2M/tools/mmcm_drp_table.py --fref 100 --divclk 1 --mult 13.5 --clkout CLKOUT0=25 --clkout CLKOUT1=25 --target 0 --name democore_clk -o CORE/vhdl/dfx/democore_clk_pkg.vhd
--
-- MMCM preset: fref=100.0 MHz, DIVCLK=1, MULT=13.5 (VCO=1350 MHz)
--   CLKOUT0_DIVIDE = 25  ->  54 MHz
--   CLKOUT1_DIVIDE = 25  ->  54 MHz
--
-- Row format (42 bit): [41:39] drp_target, [38:32] daddr, [31:16] data,
-- [15:0] read mask (shell writes (read & mask) | data).
----------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;

package democore_clk_pkg is
   constant C_DEMOCORE_CLK_ROWS : natural := 14;
   function democore_clk_row(idx : natural) return std_logic_vector;
end package democore_clk_pkg;

package body democore_clk_pkg is

   function democore_clk_row(idx : natural) return std_logic_vector is
      variable v : std_logic_vector(41 downto 0);
   begin
      v := (others => '0');
      case idx is
         when  0 => v := "000" & "0001000" & x"130D" & x"1000";  -- CLKOUT0 Register 1 (divide 25) (daddr 0x08)
         when  1 => v := "000" & "0001001" & x"0080" & x"8000";  -- CLKOUT0 Register 2 (daddr 0x09)
         when  2 => v := "000" & "0001010" & x"130D" & x"1000";  -- CLKOUT1 Register 1 (divide 25) (daddr 0x0A)
         when  3 => v := "000" & "0001011" & x"0080" & x"8000";  -- CLKOUT1 Register 2 (daddr 0x0B)
         when  4 => v := "000" & "0010100" & x"0186" & x"1000";  -- CLKFBOUT Register 1 (divide 13.500) (daddr 0x14)
         when  5 => v := "000" & "0010101" & x"4880" & x"8000";  -- CLKFBOUT Register 2 (fractional) (daddr 0x15)
         when  6 => v := "000" & "0010011" & x"3040" & x"C000";  -- CLKOUT6 Reg2 + FRAC_TIME (daddr 0x13) (daddr 0x13)
         when  7 => v := "000" & "0010110" & x"1041" & x"C000";  -- DIVCLK Register (divide 1) (daddr 0x16)
         when  8 => v := "000" & "0011000" & x"02EE" & x"FC00";  -- Lock Register 1 (daddr 0x18)
         when  9 => v := "000" & "0011001" & x"7C01" & x"8000";  -- Lock Register 2 (daddr 0x19)
         when 10 => v := "000" & "0011010" & x"7FE9" & x"8000";  -- Lock Register 3 (daddr 0x1A)
         when 11 => v := "000" & "0101000" & x"FFFF" & x"0000";  -- Power Register (daddr 0x28)
         when 12 => v := "000" & "1001110" & x"9900" & x"66FF";  -- Filter Register 1 (daddr 0x4E)
         when 13 => v := "000" & "1001111" & x"8100" & x"666F";  -- Filter Register 2 (daddr 0x4F)
         when others => null;
      end case;
      return v;
   end function democore_clk_row;

end package body democore_clk_pkg;

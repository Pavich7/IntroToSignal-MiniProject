library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- SPI mode 0, 1 MHz, MSB-first. All logic runs on the FPGA 50 MHz clock.
-- The header are sent around the BRAM payload: no extra frame RAM.
entity audio_packet_spi is
    port (
        clk, reset_n : in std_logic;
        spi_sclk, spi_cs_n, ack : in std_logic;
        spi_miso, ready : out std_logic;
        block_ready : in std_logic;
        head_sequence, head_first, head_drops, head_errors : in unsigned(31 downto 0);
        read_address : out unsigned(9 downto 0);
        read_data : in std_logic_vector(15 downto 0);
        release_block : out std_logic
    );
end entity;

architecture rtl of audio_packet_spi is
    constant FRAME_BYTES : natural := 2056;
    signal sclk_sync, cs_sync, ack_sync : std_logic_vector(2 downto 0);
    attribute altera_attribute : string;
    attribute altera_attribute of sclk_sync, cs_sync, ack_sync : signal is
        "-name SYNCHRONIZER_IDENTIFICATION FORCED";
    signal active, complete : std_logic := '0';
    signal byte_index : integer range 0 to FRAME_BYTES - 1 := 0;
    signal bit_index : integer range 0 to 7 := 0;
    signal tx_shift : std_logic_vector(7 downto 0) := (others => '0');
    function frame_byte(position : natural; seq : unsigned(31 downto 0);
        word : std_logic_vector(15 downto 0)) return std_logic_vector is
        variable shifted : unsigned(31 downto 0);
    begin
        case position is
            when 0 => return x"53"; -- S
            when 1 => return x"33"; -- 3
            when 2 => return x"41"; -- A
            when 3 => return x"32"; -- 2: simple protocol, resampled 16 kS/s
            when 4 to 7 =>
                shifted := shift_right(seq, (position-4)*8);
                return std_logic_vector(shifted(7 downto 0));
            when others =>
                if position mod 2 = 0 then return word(7 downto 0);
                else return word(15 downto 8); end if;
        end case;
    end function;

begin
    -- READY is suppressed during ACK; the ESP32 gives 2 us for it to settle.
    ready <= block_ready and not ack_sync(1) and reset_n;
    spi_miso <= tx_shift(7) when active = '1' else '0';
    read_address <= to_unsigned((byte_index - 8) / 2, 10)
        when byte_index >= 8 else (others => '0');

    process (clk, reset_n)
        variable next_byte : std_logic_vector(7 downto 0);
    begin
        if reset_n = '0' then
            sclk_sync <= "000";
            cs_sync <= "111";
            ack_sync <= "000";
            active <= '0';
            complete <= '0';
            release_block <= '0';
            byte_index <= 0;
            bit_index <= 0;
            tx_shift <= (others => '0');
        elsif rising_edge(clk) then
            sclk_sync <= sclk_sync(1 downto 0) & spi_sclk;
            cs_sync <= cs_sync(1 downto 0) & spi_cs_n;
            ack_sync <= ack_sync(1 downto 0) & ack;
            release_block <= '0';

            if ack_sync(2 downto 1) = "01" and cs_sync(1) = '1' and complete = '1' then
                release_block <= '1';
                complete <= '0';
            end if;

            if cs_sync(2 downto 1) = "10" then
                active <= block_ready and not ack_sync(1);
                complete <= '0';
                byte_index <= 0;
                bit_index <= 0;
                tx_shift <= x"53";
            elsif cs_sync(1) = '1' then
                active <= '0';
            elsif active = '1' then
                if sclk_sync(2 downto 1) = "01" then
                    if complete = '1' then -- extra clocks invalidate this read
                        complete <= '0';
                        active <= '0';
                    elsif bit_index = 7 then
                        bit_index <= 0;
                        if byte_index = FRAME_BYTES - 1 then
                            complete <= '1';
                        else
                            byte_index <= byte_index + 1;
                        end if;
                    else
                        bit_index <= bit_index + 1;
                    end if;
                elsif sclk_sync(2 downto 1) = "10" and complete = '0' then
                    if bit_index = 0 then
                        -- RAM address changed at the previous rising SCLK edge.
                        -- Its synchronous output is ready well before this edge.
                        next_byte := frame_byte(byte_index, head_sequence, read_data);
                        tx_shift <= next_byte;
                    else
                        tx_shift <= tx_shift(6 downto 0) & '0';
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;

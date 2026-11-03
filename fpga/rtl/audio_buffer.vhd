library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Two 1024 x 16-bit buffers in one simple dual-port BRAM.
-- Port A writes ADC samples; port B reads samples for SPI, both at 50 MHz.
entity audio_buffer is
    port (
        clk, reset_n : in std_logic;
        request_tick, sample_valid : in std_logic;
        request_index, sample_index, timing_errors : in unsigned(31 downto 0);
        sample_data : in std_logic_vector(11 downto 0);
        release_block : in std_logic;
        read_address : in unsigned(9 downto 0);
        read_data : out std_logic_vector(15 downto 0);
        block_ready : out std_logic;
        head_sequence, head_first, head_drops, head_errors : out unsigned(31 downto 0);
        dropped_blocks : out unsigned(31 downto 0)
    );
end entity;

architecture rtl of audio_buffer is
    type ram_type is array (0 to 2047) of std_logic_vector(15 downto 0);
    signal ram : ram_type;
    attribute ramstyle : string;
    attribute ramstyle of ram : signal is "M9K";
    type metadata_type is array (0 to 1) of unsigned(31 downto 0);
    signal sequences, firsts, drops, errors : metadata_type;
    signal full : std_logic_vector(1 downto 0) := "00";
    signal write_bank, read_bank : integer range 0 to 1 := 0;
    signal writing, started, block_done : std_logic := '0';
    signal expected_slot : integer range 0 to 1023 := 0;
    signal next_sequence, current_sequence, current_first : unsigned(31 downto 0) := (others => '0');
    signal drop_count : unsigned(31 downto 0) := (others => '0');
    signal write_enable : std_logic := '0';
    signal write_address : integer range 0 to 2047 := 0;
    signal write_data : std_logic_vector(15 downto 0);
begin
    block_ready <= full(read_bank);
    head_sequence <= sequences(read_bank);
    head_first <= firsts(read_bank);
    head_drops <= drops(read_bank);
    head_errors <= errors(read_bank);
    dropped_blocks <= drop_count;

    -- No reset of the RAM array: Quartus can implement it in M9K blocks.
    process (clk)
    begin
        if rising_edge(clk) then
            if write_enable = '1' then
                ram(write_address) <= write_data;
            end if;
            read_data <= ram(read_bank * 1024 + to_integer(read_address));
        end if;
    end process;

    process (clk, reset_n)
    begin
        if reset_n = '0' then
            full <= "00";
            write_bank <= 0;
            read_bank <= 0;
            writing <= '0';
            started <= '0';
            block_done <= '0';
            expected_slot <= 0;
            next_sequence <= (others => '0');
            current_sequence <= (others => '0');
            current_first <= (others => '0');
            drop_count <= (others => '0');
            write_enable <= '0';
            write_address <= 0;
            write_data <= (others => '0');
            sequences <= (others => (others => '0'));
            firsts <= (others => (others => '0'));
            drops <= (others => (others => '0'));
            errors <= (others => (others => '0'));
        elsif rising_edge(clk) then
            write_enable <= '0';

            -- Only ACK after a complete SPI read may release the oldest block.
            if release_block = '1' and full(read_bank) = '1' then
                full(read_bank) <= '0';
                read_bank <= 1 - read_bank;
            end if;

            -- Start at a scheduled block boundary, even if storage is full.
            if request_tick = '1' and request_index(9 downto 0) = 0 then
                if started = '1' and block_done = '0' then
                    drop_count <= drop_count + 1;
                end if;
                started <= '1';
                block_done <= '0';
                current_sequence <= next_sequence;
                next_sequence <= next_sequence + 1;
                current_first <= request_index;
                expected_slot <= 0;
                writing <= not full(write_bank);
            elsif sample_valid = '1' and writing = '1' then
                -- Reject an incomplete block rather than repeat/fabricate data.
                if sample_index(31 downto 10) /= current_first(31 downto 10)
                    or to_integer(sample_index(9 downto 0)) /= expected_slot then
                    writing <= '0';
                else
                    write_enable <= '1';
                    write_address <= write_bank * 1024 + expected_slot;
                    write_data <= "0000" & sample_data;
                    if expected_slot = 1023 then
                        sequences(write_bank) <= current_sequence;
                        firsts(write_bank) <= current_first;
                        drops(write_bank) <= drop_count;
                        errors(write_bank) <= timing_errors;
                        full(write_bank) <= '1';
                        write_bank <= 1 - write_bank;
                        writing <= '0';
                        block_done <= '1';
                    else
                        expected_slot <= expected_slot + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end architecture;

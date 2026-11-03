library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity task3_adc_top is
    port (
        MAX10_CLK1_50 : in std_logic;
        KEY : in std_logic_vector(0 downto 0);
        LEDR : out std_logic_vector(9 downto 0);
        GPIO : inout std_logic_vector(6 downto 0)
    );
end entity;

architecture rtl of task3_adc_top is
    signal sample_data : std_logic_vector(11 downto 0);
    signal sample_valid, request_tick, reset_n, pll_locked, timing_fault : std_logic;
    signal request_width, sample_width : natural range 0 to 50 := 0;
    signal request_index, sample_index, timing_errors, dropped_blocks : unsigned(31 downto 0);
    signal head_sequence, head_first, head_drops, head_errors : unsigned(31 downto 0);
    signal read_address : unsigned(9 downto 0);
    signal read_data : std_logic_vector(15 downto 0);
    signal block_ready, release_block : std_logic;
begin
    capture : entity work.audio_capture
        port map (
            clk_50 => MAX10_CLK1_50, reset_button_n => KEY(0),
            sample_data => sample_data, sample_valid => sample_valid,
            request_tick => request_tick, reset_n_out => reset_n,
            pll_locked_out => pll_locked, timing_fault => timing_fault,
            request_index => request_index, sample_index => sample_index,
            timing_errors => timing_errors
        );

    storage : entity work.audio_buffer
        port map (
            clk => MAX10_CLK1_50, reset_n => reset_n,
            request_tick => request_tick, sample_valid => sample_valid,
            request_index => request_index, sample_index => sample_index,
            timing_errors => timing_errors, sample_data => sample_data,
            release_block => release_block, read_address => read_address,
            read_data => read_data, block_ready => block_ready,
            head_sequence => head_sequence, head_first => head_first,
            head_drops => head_drops, head_errors => head_errors,
            dropped_blocks => dropped_blocks
        );

    sender : entity work.audio_packet_spi
        port map (
            clk => MAX10_CLK1_50, reset_n => reset_n,
            spi_sclk => GPIO(2), spi_cs_n => GPIO(4), ack => GPIO(6),
            spi_miso => GPIO(3), ready => GPIO(5),
            block_ready => block_ready,
            head_sequence => head_sequence, head_first => head_first,
            head_drops => head_drops, head_errors => head_errors,
            read_address => read_address, read_data => read_data,
            release_block => release_block
        );
    GPIO(2) <= 'Z'; -- inputs from the ESP32
    GPIO(4) <= 'Z';
    GPIO(6) <= 'Z';

    LEDR(5 downto 0) <= sample_data(11 downto 6);
    LEDR(6) <= block_ready;
    LEDR(7) <= '1' when dropped_blocks /= 0 else '0';
    LEDR(8) <= pll_locked;
    LEDR(9) <= timing_fault;

    -- Stretch diagnostic pulses to 1 us so an oscilloscope can show them easily.
    -- Internal sample_valid remains exactly ONE 50 MHz cycle (20 ns).
    process (MAX10_CLK1_50, reset_n)
    begin
        if reset_n = '0' then
            request_width <= 0;
            sample_width <= 0;
        elsif rising_edge(MAX10_CLK1_50) then
            if request_tick = '1' then
                request_width <= 50;
            elsif request_width > 0 then
                request_width <= request_width - 1;
            end if;
            if sample_valid = '1' then
                sample_width <= 50;
            elsif sample_width > 0 then
                sample_width <= sample_width - 1;
            end if;
        end if;
    end process;
    GPIO(0) <= '1' when request_width > 0 else '0';
    GPIO(1) <= '1' when sample_width > 0 else '0';
end architecture;

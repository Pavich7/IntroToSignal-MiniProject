library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
library audio_adc;

-- Continuous ADC acquisition and resampling, independent of SPI transfer.
entity audio_capture is
    port (
        clk_50, reset_button_n : in std_logic;
        sample_data : out std_logic_vector(11 downto 0);
        sample_valid, request_tick : out std_logic;
        request_index, sample_index, timing_errors : out unsigned(31 downto 0);
        reset_n_out, pll_locked_out, timing_fault : out std_logic
    );
end entity;

architecture rtl of audio_capture is
    -- Declare only the PLL parameters we use. Passing the legacy defaults from
    -- altera_mf_components would also override MAX 10's physical counter setup.
    component altpll is
        generic (
            intended_device_family, operation_mode : string;
            inclk0_input_frequency, clk0_multiply_by, clk0_divide_by : natural;
            clk0_duty_cycle : natural;
            compensate_clock : string;
            width_clock : natural;
            port_clk0, port_inclk0, port_areset, port_locked, lpm_type : string
        );
        port (
            inclk : in std_logic_vector(1 downto 0);
            areset : in std_logic;
            clk : out std_logic_vector(4 downto 0);
            locked : out std_logic
        );
    end component;
    signal pll_clocks : std_logic_vector(4 downto 0);
    signal pll_locked, reset_async_n, reset_n : std_logic;
    signal reset_sync : std_logic_vector(1 downto 0) := "00";
    signal command_valid, command_ready : std_logic;
    signal command_2_valid, command_2_ready : std_logic;
    signal response_valid : std_logic;
    signal response_data : std_logic_vector(11 downto 0);
    attribute altera_attribute : string;
    attribute altera_attribute of reset_sync : signal is
        "-name SYNCHRONIZER_IDENTIFICATION FORCED";
begin
    -- The ADC needs a dedicated PLL C0 route; a logic clock divider is not enough.
    adc_pll : altpll
        generic map (
            intended_device_family => "MAX 10",
            operation_mode => "NORMAL",
            inclk0_input_frequency => 20000,
            clk0_multiply_by => 1,
            clk0_divide_by => 5,
            clk0_duty_cycle => 50,
            compensate_clock => "CLK0",
            width_clock => 5,
            port_clk0 => "PORT_USED",
            port_inclk0 => "PORT_USED",
            port_areset => "PORT_USED",
            port_locked => "PORT_USED",
            lpm_type => "altpll"
        )
        port map (
            inclk => '0' & clk_50,
            areset => not reset_button_n,
            clk => pll_clocks,
            locked => pll_locked
        );

    -- Assert reset immediately; release it on the 50 MHz clock after PLL lock.
    reset_async_n <= reset_button_n and pll_locked;
    process (clk_50, reset_async_n)
    begin
        if reset_async_n = '0' then
            reset_sync <= "00";
        elsif rising_edge(clk_50) then
            reset_sync <= reset_sync(0) & '1';
        end if;
    end process;
    reset_n <= reset_sync(1);
    reset_n_out <= reset_n;
    pll_locked_out <= pll_locked;

    sampler : entity work.adc_sampler
        port map (
            clk => clk_50, reset_n => reset_n,
            command_ready => command_ready,
            command_2_ready => command_2_ready,
            response_valid => response_valid, response_data => response_data,
            command_valid => command_valid, command_2_valid => command_2_valid,
            sample_data => sample_data, sample_valid => sample_valid,
            request_tick => request_tick, timing_fault => timing_fault,
            request_index => request_index, sample_index => sample_index,
            timing_errors => timing_errors
        );

    adc : entity audio_adc.audio_adc
        port map (
            clock_clk => clk_50,
            reset_reset_n => reset_n,
            pll_clock_clk => pll_clocks(0),
            pll_locked_export => pll_locked,
            -- ADC1 channel 1 = Arduino A0 on DE10-Lite.
            command_valid => command_valid,
            command_channel => "00001",
            command_startofpacket => '1', command_endofpacket => '1',
            command_ready => command_ready,
            -- Both controllers of the Dual ADC IP must advance together.
            -- ADC2 samples its dedicated channel; that result is unused.
            command_2_valid => command_2_valid,
            command_2_channel => "00000",
            command_2_startofpacket => '1', command_2_endofpacket => '1',
            command_2_ready => command_2_ready,
            response_valid => response_valid, response_data => response_data,
            response_channel => open,
            response_startofpacket => open, response_endofpacket => open,
            response_2_valid => open, response_2_data => open,
            response_2_channel => open,
            response_2_startofpacket => open, response_2_endofpacket => open
        );
end architecture;

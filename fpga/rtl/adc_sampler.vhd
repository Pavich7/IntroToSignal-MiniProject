library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Continuous 1 MS/s ADC -> linear interpolation -> uniform 16 kS/s output.
-- Input MUST be band-limited below 8 kHz; interpolation is not an anti-alias filter.
entity adc_sampler is
    port (
        clk, reset_n : in std_logic;
        command_ready, command_2_ready : in std_logic;
        response_valid : in std_logic;
        response_data : in std_logic_vector(11 downto 0);
        command_valid, command_2_valid : out std_logic;
        sample_data : out std_logic_vector(11 downto 0);
        sample_valid, request_tick : out std_logic;
        request_index, sample_index, timing_errors : out unsigned(31 downto 0);
        timing_fault : out std_logic
    );
end entity;

architecture rtl of adc_sampler is
    signal startup : natural range 0 to 50000 := 0;
    signal running, failed, pending, deliver : std_logic := '0';
    signal period_count : natural range 0 to 3124 := 0;
    signal input_age : natural range 0 to 52 := 0;
    signal phase : natural range 0 to 124 := 0;
    signal previous, interpolated : unsigned(11 downto 0) := (others => '0');
    signal next_index, error_count : unsigned(31 downto 0) := (others => '0');
begin
    -- Holding valid high requests consecutive conversions. Both controllers
    -- consume identical constant commands whenever each asserts ready.
    command_valid <= '1' when startup = 50000 else '0';
    command_2_valid <= '1' when startup = 50000 else '0';
    timing_fault <= failed;
    timing_errors <= error_count;

    process (clk, reset_n)
        variable pair_sum : unsigned(12 downto 0);
    begin
        if reset_n = '0' then
            startup <= 0;
            running <= '0'; failed <= '0'; pending <= '0'; deliver <= '0';
            period_count <= 0; input_age <= 0; phase <= 0;
            previous <= (others => '0'); interpolated <= (others => '0');
            next_index <= (others => '0'); error_count <= (others => '0');
            sample_data <= (others => '0'); sample_valid <= '0'; request_tick <= '0';
            request_index <= (others => '0'); sample_index <= (others => '0');
        elsif rising_edge(clk) then
            request_tick <= '0';
            -- Buffer sees the block-start tick one clock before sample_valid.
            sample_valid <= deliver and not failed;
            deliver <= '0';
            if startup < 50000 then startup <= startup + 1; end if;

            if running = '1' then
                if period_count = 3124 then
                    period_count <= 0;
                    request_tick <= '1';
                    request_index <= next_index;
                    sample_index <= next_index;
                    next_index <= next_index + 1;
                    if pending = '1' and failed = '0' then
                        sample_data <= std_logic_vector(interpolated);
                        deliver <= '1';
                        pending <= '0';
                    end if;
                else
                    period_count <= period_count + 1;
                end if;
                if input_age < 52 then input_age <= input_age + 1; end if;
                -- A missing conversion invalidates the time grid. Stop output
                -- until KEY0 reset, rather than hide the missing input sample.
                if input_age = 51 and response_valid = '0' and failed = '0' then
                    failed <= '1'; error_count <= error_count + 1;
                end if;
            end if;

            if response_valid = '1' and startup = 50000 then
                input_age <= 0;
                if running = '1' and (input_age < 48 or input_age > 50) and failed = '0' then
                    failed <= '1'; error_count <= error_count + 1;
                end if;
                running <= '1';
                previous <= unsigned(response_data);
                -- Positions in each 125-input interval: 0 and 62.5.
                -- Position 62.5 uses the mean of inputs 62 and 63.
                if phase = 0 then
                    interpolated <= unsigned(response_data);
                    pending <= '1';
                elsif phase = 63 then
                    pair_sum := resize(previous, 13) + resize(unsigned(response_data), 13) + 1;
                    interpolated <= pair_sum(12 downto 1);
                    pending <= '1';
                end if;
                if phase = 124 then phase <= 0; else phase <= phase + 1; end if;
            end if;
        end if;
    end process;
end architecture;

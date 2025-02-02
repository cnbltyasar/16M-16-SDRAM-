library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- This SDRAM controller provides a symmetric 32-bit synchronous interface for a 16Mx16-bit SDRAM chip
-- (e.g. AS4C16M16SA-6TCN, IS42S16400F, etc.). It supports both read and write operations, converting the
-- 32-bit external interface into a 16-bit SDRAM access. Timing parameters and interface widths can be
-- configured via generics.

entity sdram is
  generic (
    -- Clock frequency (MHz): Must be provided to calculate timing in clock cycles.
    CLK_FREQ : real;

    -- 32-bit controller interface parameters.
    ADDR_WIDTH : natural := 23;
    DATA_WIDTH : natural := 32;

    -- SDRAM interface parameters.
    SDRAM_ADDR_WIDTH : natural := 13;
    SDRAM_DATA_WIDTH : natural := 16;
    SDRAM_COL_WIDTH  : natural := 9;
    SDRAM_ROW_WIDTH  : natural := 13;
    SDRAM_BANK_WIDTH : natural := 2;

    -- CAS latency (in clock cycles). Use 2 for frequencies below 133 MHz, 3 for above.
    CAS_LATENCY : natural := 2;

    -- Burst length: Number of 16-bit words to burst in a read or write.
    BURST_LENGTH : natural := 2;

    -- Timing parameters in nanoseconds.
    T_DESL : real := 200000.0; -- Startup delay
    T_MRD  : real :=     12.0; -- Mode register cycle time
    T_RC   : real :=     60.0; -- Row cycle time
    T_RCD  : real :=     18.0; -- RAS-to-CAS delay
    T_RP   : real :=     18.0; -- Precharge to activate delay
    T_WR   : real :=     12.0; -- Write recovery time
    T_REFI : real :=   7800.0  -- Average refresh interval
  );
  port (
    -- Global signals
    reset : in std_logic := '0';
    clk   : in std_logic;

    -- External 32-bit interface signals.
    addr  : in unsigned(ADDR_WIDTH-1 downto 0);         -- 32-bit address (converted to SDRAM format)
    data  : in std_logic_vector(DATA_WIDTH-1 downto 0);   -- 32-bit data input (for writes)
    we    : in std_logic;                               -- Write enable (active when performing a write)
    req   : in std_logic;                               -- Request signal (initiates a memory access)
    ack   : out std_logic;                              -- Acknowledge: indicates that the request is accepted
    valid : out std_logic;                              -- Valid: indicates when the output data (q) is valid
    q     : out std_logic_vector(DATA_WIDTH-1 downto 0);  -- 32-bit data output (for reads)

    -- SDRAM interface signals.
    sdram_a     : out unsigned(SDRAM_ADDR_WIDTH-1 downto 0);
    sdram_ba    : out unsigned(SDRAM_BANK_WIDTH-1 downto 0);
    sdram_dq    : inout std_logic_vector(SDRAM_DATA_WIDTH-1 downto 0);
    sdram_cke   : out std_logic;
    sdram_cs_n  : out std_logic;
    sdram_ras_n : out std_logic;
    sdram_cas_n : out std_logic;
    sdram_we_n  : out std_logic;
    sdram_dqml  : out std_logic;
    sdram_dqmh  : out std_logic
  );
end sdram;

architecture arch of sdram is

  -----------------------------------------------------------------------------
  -- Function to compute ceiling of log2(n) as a natural number.
  -----------------------------------------------------------------------------
  function ilog2(n : natural) return natural is
  begin
    return natural(ceil(log2(real(n))));
  end ilog2;

  -----------------------------------------------------------------------------
  -- Command type and constants for SDRAM operations.
  -----------------------------------------------------------------------------
  subtype command_t is std_logic_vector(3 downto 0);

  constant CMD_DESELECT     : command_t := "1---";  -- Deselect command
  constant CMD_LOAD_MODE    : command_t := "0000";  -- Load mode register command
  constant CMD_AUTO_REFRESH : command_t := "0001";  -- Auto refresh command
  constant CMD_PRECHARGE    : command_t := "0010";  -- Precharge command
  constant CMD_ACTIVE       : command_t := "0011";  -- Activate row command
  constant CMD_WRITE        : command_t := "0100";  -- Write command
  constant CMD_READ         : command_t := "0101";  -- Read command
  constant CMD_STOP         : command_t := "0110";  -- Stop command (unused)
  constant CMD_NOP          : command_t := "0111";  -- No operation

  -----------------------------------------------------------------------------
  -- Burst and mode register settings.
  -----------------------------------------------------------------------------
  constant BURST_TYPE : std_logic := '0';        -- 0: sequential, 1: interleaved burst ordering.
  constant WRITE_BURST_MODE : std_logic := '0';    -- 0: burst mode, 1: single mode for writes.
  constant MODE_REG : unsigned(SDRAM_ADDR_WIDTH-1 downto 0) := (
    "000" &
    WRITE_BURST_MODE &
    "00" &
    to_unsigned(CAS_LATENCY, 3) &
    BURST_TYPE &
    to_unsigned(ilog2(BURST_LENGTH), 3)
  );

  -----------------------------------------------------------------------------
  -- Timing calculations based on provided parameters.
  -----------------------------------------------------------------------------
  constant CLK_PERIOD : real := 1.0 / CLK_FREQ * 1000.0;  -- Clock period in ns

  constant INIT_WAIT       : natural := natural(ceil(T_DESL / CLK_PERIOD));
  constant LOAD_MODE_WAIT  : natural := natural(ceil(T_MRD / CLK_PERIOD));
  constant ACTIVE_WAIT     : natural := natural(ceil(T_RCD / CLK_PERIOD));
  constant REFRESH_WAIT    : natural := natural(ceil(T_RC / CLK_PERIOD));
  constant PRECHARGE_WAIT  : natural := natural(ceil(T_RP / CLK_PERIOD));
  constant READ_WAIT       : natural := CAS_LATENCY + BURST_LENGTH;
  constant WRITE_WAIT      : natural := BURST_LENGTH + natural(ceil((T_WR + T_RP) / CLK_PERIOD));
  constant REFRESH_INTERVAL: natural := natural(floor(T_REFI / CLK_PERIOD)) - 10;

  -----------------------------------------------------------------------------
  -- State machine type definition.
  -----------------------------------------------------------------------------
  type state_t is (INIT, MODE, IDLE, ACTIVE, READ, WRITE, REFRESH);

  -----------------------------------------------------------------------------
  -- Signal declarations.
  -----------------------------------------------------------------------------
  signal state, next_state : state_t;
  signal cmd, next_cmd : command_t := CMD_NOP;

  -- Control signals for internal timing and operations.
  signal start          : std_logic;
  signal load_mode_done : std_logic;
  signal active_done    : std_logic;
  signal refresh_done   : std_logic;
  signal first_word     : std_logic;
  signal read_done      : std_logic;
  signal write_done     : std_logic;
  signal should_refresh : std_logic;

  -- Counters for timing.
  signal wait_counter    : natural range 0 to 16383;
  signal refresh_counter : natural range 0 to 1023;

  -- Internal registers for address, data, and control.
  signal addr_reg : unsigned(SDRAM_COL_WIDTH + SDRAM_ROW_WIDTH + SDRAM_BANK_WIDTH - 1 downto 0);
  signal data_reg : std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal we_reg   : std_logic;
  signal q_reg    : std_logic_vector(DATA_WIDTH - 1 downto 0);

  -- Aliases to extract column, row, and bank from the latched address.
  alias col  : unsigned(SDRAM_COL_WIDTH - 1 downto 0) is addr_reg(SDRAM_COL_WIDTH - 1 downto 0);
  alias row  : unsigned(SDRAM_ROW_WIDTH - 1 downto 0) is addr_reg(SDRAM_COL_WIDTH + SDRAM_ROW_WIDTH - 1 downto SDRAM_COL_WIDTH);
  alias bank : unsigned(SDRAM_BANK_WIDTH - 1 downto 0) is addr_reg(SDRAM_COL_WIDTH + SDRAM_ROW_WIDTH + SDRAM_BANK_WIDTH - 1 downto SDRAM_COL_WIDTH + SDRAM_ROW_WIDTH);

begin

  -----------------------------------------------------------------------------
  -- Main Finite State Machine (FSM) for SDRAM operations.
  -----------------------------------------------------------------------------
  fsm : process (state, wait_counter, req, we_reg, load_mode_done, active_done, refresh_done, read_done, write_done, should_refresh)
  begin
    next_state <= state;
    next_cmd   <= CMD_NOP;  -- Default: No operation

    case state is
      -- INIT: Initialization sequence.
      when INIT =>
        if wait_counter = 0 then
          next_cmd <= CMD_DESELECT;  -- Begin with de-select
        elsif wait_counter = INIT_WAIT - 1 then
          next_cmd <= CMD_PRECHARGE;   -- Precharge all rows
        elsif wait_counter = INIT_WAIT + PRECHARGE_WAIT - 1 then
          next_cmd <= CMD_AUTO_REFRESH;  -- First auto-refresh command
        elsif wait_counter = INIT_WAIT + PRECHARGE_WAIT + REFRESH_WAIT - 1 then
          next_cmd <= CMD_AUTO_REFRESH;  -- Second auto-refresh command
        elsif wait_counter = INIT_WAIT + PRECHARGE_WAIT + REFRESH_WAIT + REFRESH_WAIT - 1 then
          next_state <= MODE;            -- Move to mode register programming
          next_cmd   <= CMD_LOAD_MODE;
        end if;

      -- MODE: Load mode register with configuration.
      when MODE =>
        if load_mode_done = '1' then
          next_state <= IDLE;
        end if;

      -- IDLE: Wait for a request or refresh condition.
      when IDLE =>
        if should_refresh = '1' then
          next_state <= REFRESH;
          next_cmd   <= CMD_AUTO_REFRESH;
        elsif req = '1' then
          next_state <= ACTIVE;
          next_cmd   <= CMD_ACTIVE;
        end if;

      -- ACTIVE: Activate the SDRAM row for the upcoming access.
      when ACTIVE =>
        if active_done = '1' then
          if we_reg = '1' then
            next_state <= WRITE;
            next_cmd   <= CMD_WRITE;
          else
            next_state <= READ;
            next_cmd   <= CMD_READ;
          end if;
        end if;

      -- READ: Perform a read operation.
      when READ =>
        if read_done = '1' then
          if should_refresh = '1' then
            next_state <= REFRESH;
            next_cmd   <= CMD_AUTO_REFRESH;
          elsif req = '1' then
            next_state <= ACTIVE;
            next_cmd   <= CMD_ACTIVE;
          else
            next_state <= IDLE;
          end if;
        end if;

      -- WRITE: Perform a write operation.
      when WRITE =>
        if write_done = '1' then
          if should_refresh = '1' then
            next_state <= REFRESH;
            next_cmd   <= CMD_AUTO_REFRESH;
          elsif req = '1' then
            next_state <= ACTIVE;
            next_cmd   <= CMD_ACTIVE;
          else
            next_state <= IDLE;
          end if;
        end if;

      -- REFRESH: Execute an auto-refresh command.
      when REFRESH =>
        if refresh_done = '1' then
          if req = '1' then
            next_state <= ACTIVE;
            next_cmd   <= CMD_ACTIVE;
          else
            next_state <= IDLE;
          end if;
        end if;
    end case;
  end process;

  -----------------------------------------------------------------------------
  -- Latch next state and command on rising edge of clock.
  -----------------------------------------------------------------------------
  latch_next_state : process (clk, reset)
  begin
    if reset = '1' then
      state <= INIT;
      cmd   <= CMD_NOP;
    elsif rising_edge(clk) then
      state <= next_state;
      cmd   <= next_cmd;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Wait counter: Provides delay as required by SDRAM timing specifications.
  -----------------------------------------------------------------------------
  update_wait_counter : process (clk, reset)
  begin
    if reset = '1' then
      wait_counter <= 0;
    elsif rising_edge(clk) then
      if state /= next_state then  -- Reset counter on state change.
        wait_counter <= 0;
      else
        wait_counter <= wait_counter + 1;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Refresh counter: Triggers a refresh when the refresh interval is reached.
  -----------------------------------------------------------------------------
  update_refresh_counter : process (clk, reset)
  begin
    if reset = '1' then
      refresh_counter <= 0;
    elsif rising_edge(clk) then
      if state = REFRESH and wait_counter = 0 then
        refresh_counter <= 0;
      else
        refresh_counter <= refresh_counter + 1;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Request latching: Capture the external address, data, and write enable.
  -- The address is shifted left by one (multiplied by 2) to convert from the
  -- 32-bit controller address to the 16-bit SDRAM address format.
  -----------------------------------------------------------------------------
  latch_request : process (clk)
  begin
    if rising_edge(clk) then
      if start = '1' then
        addr_reg <= shift_left(resize(addr, addr_reg'length), 1);
        data_reg <= data;
        we_reg   <= we;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Data latching for read operations: Assemble a 32-bit word from two 16-bit bursts.
  -----------------------------------------------------------------------------
  latch_sdram_data : process (clk)
  begin
    if rising_edge(clk) then
      valid <= '0';
      if state = READ then
        if first_word = '1' then
          q_reg(31 downto 16) <= sdram_dq;
        elsif read_done = '1' then
          q_reg(15 downto 0) <= sdram_dq;
          valid <= '1';  -- Entire 32-bit word is now valid.
        end if;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Generate timing signals based on the wait counter.
  -----------------------------------------------------------------------------
  load_mode_done <= '1' when wait_counter = LOAD_MODE_WAIT - 1 else '0';
  active_done    <= '1' when wait_counter = ACTIVE_WAIT - 1    else '0';
  refresh_done   <= '1' when wait_counter = REFRESH_WAIT - 1   else '0';
  first_word     <= '1' when wait_counter = CAS_LATENCY       else '0';
  read_done      <= '1' when wait_counter = READ_WAIT - 1       else '0';
  write_done     <= '1' when wait_counter = WRITE_WAIT - 1      else '0';

  -----------------------------------------------------------------------------
  -- Determine when a refresh is needed.
  -----------------------------------------------------------------------------
  should_refresh <= '1' when refresh_counter >= REFRESH_INTERVAL - 1 else '0';

  -----------------------------------------------------------------------------
  -- The 'start' signal indicates when a new request can be latched. It is only
  -- asserted at the end of the IDLE, READ, WRITE, or REFRESH states.
  -----------------------------------------------------------------------------
  start <= '1' when (state = IDLE) or
                    (state = READ and read_done = '1') or
                    (state = WRITE and write_done = '1') or
                    (state = REFRESH and refresh_done = '1') else '0';

  -----------------------------------------------------------------------------
  -- Acknowledge signal: Asserted at the beginning of the ACTIVE state.
  -----------------------------------------------------------------------------
  ack <= '1' when state = ACTIVE and wait_counter = 0 else '0';

  -----------------------------------------------------------------------------
  -- Output assignments.
  -----------------------------------------------------------------------------
  q <= q_reg;  -- Data output for read operations.

  -- SDRAM clock enable: Deasserted at the beginning of INIT.
  sdram_cke <= '0' when state = INIT and wait_counter = 0 else '1';

  -- SDRAM control signals are driven by the current command.
  (sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n) <= cmd;

  -----------------------------------------------------------------------------
  -- SDRAM bank and address assignment based on state.
  -----------------------------------------------------------------------------
  with state select
    sdram_ba <=
      bank            when ACTIVE,
      bank            when READ,
      bank            when WRITE,
      (others => '0') when others;

  with state select
    sdram_a <=
      "0010000000000" when INIT,        -- Fixed address during initialization.
      MODE_REG        when MODE,        -- Mode register configuration.
      row             when ACTIVE,      -- Row address during activation.
      "0010" & col    when READ,        -- Column address with auto-precharge for read.
      "0010" & col    when WRITE,       -- Column address with auto-precharge for write.
      (others => '0') when others;

  -----------------------------------------------------------------------------
  -- SDRAM data bus assignment for write operations.
  -- Data is output during WRITE state; otherwise, the bus is tri-stated.
  -----------------------------------------------------------------------------
  sdram_dq <= data_reg((BURST_LENGTH - wait_counter) * SDRAM_DATA_WIDTH - 1 downto
                       (BURST_LENGTH - wait_counter - 1) * SDRAM_DATA_WIDTH)
             when state = WRITE else (others => 'Z');

  -----------------------------------------------------------------------------
  -- Data mask signals: Currently not used (set to '0' to disable masking).
  -----------------------------------------------------------------------------
  sdram_dqmh <= '0';
  sdram_dqml <= '0';

end architecture arch;
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

-- This SDRAM controller provides a symmetric 32-bit synchronous interface for a 16Mx16-bit SDRAM chip
-- (e.g. AS4C16M16SA-6TCN, IS42S16400F, etc.). It supports both read and write operations, converting the
-- 32-bit external interface into a 16-bit SDRAM access. Timing parameters and interface widths can be
-- configured via generics.

entity sdram is
  generic (
    -- Clock frequency (MHz): Must be provided to calculate timing in clock cycles.
    CLK_FREQ : real;

    -- 32-bit controller interface parameters.
    ADDR_WIDTH : natural := 23;
    DATA_WIDTH : natural := 32;

    -- SDRAM interface parameters.
    SDRAM_ADDR_WIDTH : natural := 13;
    SDRAM_DATA_WIDTH : natural := 16;
    SDRAM_COL_WIDTH  : natural := 9;
    SDRAM_ROW_WIDTH  : natural := 13;
    SDRAM_BANK_WIDTH : natural := 2;

    -- CAS latency (in clock cycles). Use 2 for frequencies below 133 MHz, 3 for above.
    CAS_LATENCY : natural := 2;

    -- Burst length: Number of 16-bit words to burst in a read or write.
    BURST_LENGTH : natural := 2;

    -- Timing parameters in nanoseconds.
    T_DESL : real := 200000.0; -- Startup delay
    T_MRD  : real :=     12.0; -- Mode register cycle time
    T_RC   : real :=     60.0; -- Row cycle time
    T_RCD  : real :=     18.0; -- RAS-to-CAS delay
    T_RP   : real :=     18.0; -- Precharge to activate delay
    T_WR   : real :=     12.0; -- Write recovery time
    T_REFI : real :=   7800.0  -- Average refresh interval
  );
  port (
    -- Global signals
    reset : in std_logic := '0';
    clk   : in std_logic;

    -- External 32-bit interface signals.
    addr  : in unsigned(ADDR_WIDTH-1 downto 0);         -- 32-bit address (converted to SDRAM format)
    data  : in std_logic_vector(DATA_WIDTH-1 downto 0);   -- 32-bit data input (for writes)
    we    : in std_logic;                               -- Write enable (active when performing a write)
    req   : in std_logic;                               -- Request signal (initiates a memory access)
    ack   : out std_logic;                              -- Acknowledge: indicates that the request is accepted
    valid : out std_logic;                              -- Valid: indicates when the output data (q) is valid
    q     : out std_logic_vector(DATA_WIDTH-1 downto 0);  -- 32-bit data output (for reads)

    -- SDRAM interface signals.
    sdram_a     : out unsigned(SDRAM_ADDR_WIDTH-1 downto 0);
    sdram_ba    : out unsigned(SDRAM_BANK_WIDTH-1 downto 0);
    sdram_dq    : inout std_logic_vector(SDRAM_DATA_WIDTH-1 downto 0);
    sdram_cke   : out std_logic;
    sdram_cs_n  : out std_logic;
    sdram_ras_n : out std_logic;
    sdram_cas_n : out std_logic;
    sdram_we_n  : out std_logic;
    sdram_dqml  : out std_logic;
    sdram_dqmh  : out std_logic
  );
end sdram;

architecture arch of sdram is

  -----------------------------------------------------------------------------
  -- Function to compute ceiling of log2(n) as a natural number.
  -----------------------------------------------------------------------------
  function ilog2(n : natural) return natural is
  begin
    return natural(ceil(log2(real(n))));
  end ilog2;

  -----------------------------------------------------------------------------
  -- Command type and constants for SDRAM operations.
  -----------------------------------------------------------------------------
  subtype command_t is std_logic_vector(3 downto 0);

  constant CMD_DESELECT     : command_t := "1---";  -- Deselect command
  constant CMD_LOAD_MODE    : command_t := "0000";  -- Load mode register command
  constant CMD_AUTO_REFRESH : command_t := "0001";  -- Auto refresh command
  constant CMD_PRECHARGE    : command_t := "0010";  -- Precharge command
  constant CMD_ACTIVE       : command_t := "0011";  -- Activate row command
  constant CMD_WRITE        : command_t := "0100";  -- Write command
  constant CMD_READ         : command_t := "0101";  -- Read command
  constant CMD_STOP         : command_t := "0110";  -- Stop command (unused)
  constant CMD_NOP          : command_t := "0111";  -- No operation

  -----------------------------------------------------------------------------
  -- Burst and mode register settings.
  -----------------------------------------------------------------------------
  constant BURST_TYPE : std_logic := '0';        -- 0: sequential, 1: interleaved burst ordering.
  constant WRITE_BURST_MODE : std_logic := '0';    -- 0: burst mode, 1: single mode for writes.
  constant MODE_REG : unsigned(SDRAM_ADDR_WIDTH-1 downto 0) := (
    "000" &
    WRITE_BURST_MODE &
    "00" &
    to_unsigned(CAS_LATENCY, 3) &
    BURST_TYPE &
    to_unsigned(ilog2(BURST_LENGTH), 3)
  );

  -----------------------------------------------------------------------------
  -- Timing calculations based on provided parameters.
  -----------------------------------------------------------------------------
  constant CLK_PERIOD : real := 1.0 / CLK_FREQ * 1000.0;  -- Clock period in ns

  constant INIT_WAIT       : natural := natural(ceil(T_DESL / CLK_PERIOD));
  constant LOAD_MODE_WAIT  : natural := natural(ceil(T_MRD / CLK_PERIOD));
  constant ACTIVE_WAIT     : natural := natural(ceil(T_RCD / CLK_PERIOD));
  constant REFRESH_WAIT    : natural := natural(ceil(T_RC / CLK_PERIOD));
  constant PRECHARGE_WAIT  : natural := natural(ceil(T_RP / CLK_PERIOD));
  constant READ_WAIT       : natural := CAS_LATENCY + BURST_LENGTH;
  constant WRITE_WAIT      : natural := BURST_LENGTH + natural(ceil((T_WR + T_RP) / CLK_PERIOD));
  constant REFRESH_INTERVAL: natural := natural(floor(T_REFI / CLK_PERIOD)) - 10;

  -----------------------------------------------------------------------------
  -- State machine type definition.
  -----------------------------------------------------------------------------
  type state_t is (INIT, MODE, IDLE, ACTIVE, READ, WRITE, REFRESH);

  -----------------------------------------------------------------------------
  -- Signal declarations.
  -----------------------------------------------------------------------------
  signal state, next_state : state_t;
  signal cmd, next_cmd : command_t := CMD_NOP;

  -- Control signals for internal timing and operations.
  signal start          : std_logic;
  signal load_mode_done : std_logic;
  signal active_done    : std_logic;
  signal refresh_done   : std_logic;
  signal first_word     : std_logic;
  signal read_done      : std_logic;
  signal write_done     : std_logic;
  signal should_refresh : std_logic;

  -- Counters for timing.
  signal wait_counter    : natural range 0 to 16383;
  signal refresh_counter : natural range 0 to 1023;

  -- Internal registers for address, data, and control.
  signal addr_reg : unsigned(SDRAM_COL_WIDTH + SDRAM_ROW_WIDTH + SDRAM_BANK_WIDTH - 1 downto 0);
  signal data_reg : std_logic_vector(DATA_WIDTH - 1 downto 0);
  signal we_reg   : std_logic;
  signal q_reg    : std_logic_vector(DATA_WIDTH - 1 downto 0);

  -- Aliases to extract column, row, and bank from the latched address.
  alias col  : unsigned(SDRAM_COL_WIDTH - 1 downto 0) is addr_reg(SDRAM_COL_WIDTH - 1 downto 0);
  alias row  : unsigned(SDRAM_ROW_WIDTH - 1 downto 0) is addr_reg(SDRAM_COL_WIDTH + SDRAM_ROW_WIDTH - 1 downto SDRAM_COL_WIDTH);
  alias bank : unsigned(SDRAM_BANK_WIDTH - 1 downto 0) is addr_reg(SDRAM_COL_WIDTH + SDRAM_ROW_WIDTH + SDRAM_BANK_WIDTH - 1 downto SDRAM_COL_WIDTH + SDRAM_ROW_WIDTH);

begin

  -----------------------------------------------------------------------------
  -- Main Finite State Machine (FSM) for SDRAM operations.
  -----------------------------------------------------------------------------
  fsm : process (state, wait_counter, req, we_reg, load_mode_done, active_done, refresh_done, read_done, write_done, should_refresh)
  begin
    next_state <= state;
    next_cmd   <= CMD_NOP;  -- Default: No operation

    case state is
      -- INIT: Initialization sequence.
      when INIT =>
        if wait_counter = 0 then
          next_cmd <= CMD_DESELECT;  -- Begin with de-select
        elsif wait_counter = INIT_WAIT - 1 then
          next_cmd <= CMD_PRECHARGE;   -- Precharge all rows
        elsif wait_counter = INIT_WAIT + PRECHARGE_WAIT - 1 then
          next_cmd <= CMD_AUTO_REFRESH;  -- First auto-refresh command
        elsif wait_counter = INIT_WAIT + PRECHARGE_WAIT + REFRESH_WAIT - 1 then
          next_cmd <= CMD_AUTO_REFRESH;  -- Second auto-refresh command
        elsif wait_counter = INIT_WAIT + PRECHARGE_WAIT + REFRESH_WAIT + REFRESH_WAIT - 1 then
          next_state <= MODE;            -- Move to mode register programming
          next_cmd   <= CMD_LOAD_MODE;
        end if;

      -- MODE: Load mode register with configuration.
      when MODE =>
        if load_mode_done = '1' then
          next_state <= IDLE;
        end if;

      -- IDLE: Wait for a request or refresh condition.
      when IDLE =>
        if should_refresh = '1' then
          next_state <= REFRESH;
          next_cmd   <= CMD_AUTO_REFRESH;
        elsif req = '1' then
          next_state <= ACTIVE;
          next_cmd   <= CMD_ACTIVE;
        end if;

      -- ACTIVE: Activate the SDRAM row for the upcoming access.
      when ACTIVE =>
        if active_done = '1' then
          if we_reg = '1' then
            next_state <= WRITE;
            next_cmd   <= CMD_WRITE;
          else
            next_state <= READ;
            next_cmd   <= CMD_READ;
          end if;
        end if;

      -- READ: Perform a read operation.
      when READ =>
        if read_done = '1' then
          if should_refresh = '1' then
            next_state <= REFRESH;
            next_cmd   <= CMD_AUTO_REFRESH;
          elsif req = '1' then
            next_state <= ACTIVE;
            next_cmd   <= CMD_ACTIVE;
          else
            next_state <= IDLE;
          end if;
        end if;

      -- WRITE: Perform a write operation.
      when WRITE =>
        if write_done = '1' then
          if should_refresh = '1' then
            next_state <= REFRESH;
            next_cmd   <= CMD_AUTO_REFRESH;
          elsif req = '1' then
            next_state <= ACTIVE;
            next_cmd   <= CMD_ACTIVE;
          else
            next_state <= IDLE;
          end if;
        end if;

      -- REFRESH: Execute an auto-refresh command.
      when REFRESH =>
        if refresh_done = '1' then
          if req = '1' then
            next_state <= ACTIVE;
            next_cmd   <= CMD_ACTIVE;
          else
            next_state <= IDLE;
          end if;
        end if;
    end case;
  end process;

  -----------------------------------------------------------------------------
  -- Latch next state and command on rising edge of clock.
  -----------------------------------------------------------------------------
  latch_next_state : process (clk, reset)
  begin
    if reset = '1' then
      state <= INIT;
      cmd   <= CMD_NOP;
    elsif rising_edge(clk) then
      state <= next_state;
      cmd   <= next_cmd;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Wait counter: Provides delay as required by SDRAM timing specifications.
  -----------------------------------------------------------------------------
  update_wait_counter : process (clk, reset)
  begin
    if reset = '1' then
      wait_counter <= 0;
    elsif rising_edge(clk) then
      if state /= next_state then  -- Reset counter on state change.
        wait_counter <= 0;
      else
        wait_counter <= wait_counter + 1;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Refresh counter: Triggers a refresh when the refresh interval is reached.
  -----------------------------------------------------------------------------
  update_refresh_counter : process (clk, reset)
  begin
    if reset = '1' then
      refresh_counter <= 0;
    elsif rising_edge(clk) then
      if state = REFRESH and wait_counter = 0 then
        refresh_counter <= 0;
      else
        refresh_counter <= refresh_counter + 1;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Request latching: Capture the external address, data, and write enable.
  -- The address is shifted left by one (multiplied by 2) to convert from the
  -- 32-bit controller address to the 16-bit SDRAM address format.
  -----------------------------------------------------------------------------
  latch_request : process (clk)
  begin
    if rising_edge(clk) then
      if start = '1' then
        addr_reg <= shift_left(resize(addr, addr_reg'length), 1);
        data_reg <= data;
        we_reg   <= we;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Data latching for read operations: Assemble a 32-bit word from two 16-bit bursts.
  -----------------------------------------------------------------------------
  latch_sdram_data : process (clk)
  begin
    if rising_edge(clk) then
      valid <= '0';
      if state = READ then
        if first_word = '1' then
          q_reg(31 downto 16) <= sdram_dq;
        elsif read_done = '1' then
          q_reg(15 downto 0) <= sdram_dq;
          valid <= '1';  -- Entire 32-bit word is now valid.
        end if;
      end if;
    end if;
  end process;

  -----------------------------------------------------------------------------
  -- Generate timing signals based on the wait counter.
  -----------------------------------------------------------------------------
  load_mode_done <= '1' when wait_counter = LOAD_MODE_WAIT - 1 else '0';
  active_done    <= '1' when wait_counter = ACTIVE_WAIT - 1    else '0';
  refresh_done   <= '1' when wait_counter = REFRESH_WAIT - 1   else '0';
  first_word     <= '1' when wait_counter = CAS_LATENCY       else '0';
  read_done      <= '1' when wait_counter = READ_WAIT - 1       else '0';
  write_done     <= '1' when wait_counter = WRITE_WAIT - 1      else '0';

  -----------------------------------------------------------------------------
  -- Determine when a refresh is needed.
  -----------------------------------------------------------------------------
  should_refresh <= '1' when refresh_counter >= REFRESH_INTERVAL - 1 else '0';

  -----------------------------------------------------------------------------
  -- The 'start' signal indicates when a new request can be latched. It is only
  -- asserted at the end of the IDLE, READ, WRITE, or REFRESH states.
  -----------------------------------------------------------------------------
  start <= '1' when (state = IDLE) or
                    (state = READ and read_done = '1') or
                    (state = WRITE and write_done = '1') or
                    (state = REFRESH and refresh_done = '1') else '0';

  -----------------------------------------------------------------------------
  -- Acknowledge signal: Asserted at the beginning of the ACTIVE state.
  -----------------------------------------------------------------------------
  ack <= '1' when state = ACTIVE and wait_counter = 0 else '0';

  -----------------------------------------------------------------------------
  -- Output assignments.
  -----------------------------------------------------------------------------
  q <= q_reg;  -- Data output for read operations.

  -- SDRAM clock enable: Deasserted at the beginning of INIT.
  sdram_cke <= '0' when state = INIT and wait_counter = 0 else '1';

  -- SDRAM control signals are driven by the current command.
  (sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n) <= cmd;

  -----------------------------------------------------------------------------
  -- SDRAM bank and address assignment based on state.
  -----------------------------------------------------------------------------
  with state select
    sdram_ba <=
      bank            when ACTIVE,
      bank            when READ,
      bank            when WRITE,
      (others => '0') when others;

  with state select
    sdram_a <=
      "0010000000000" when INIT,        -- Fixed address during initialization.
      MODE_REG        when MODE,        -- Mode register configuration.
      row             when ACTIVE,      -- Row address during activation.
      "0010" & col    when READ,        -- Column address with auto-precharge for read.
      "0010" & col    when WRITE,       -- Column address with auto-precharge for write.
      (others => '0') when others;

  -----------------------------------------------------------------------------
  -- SDRAM data bus assignment for write operations.
  -- Data is output during WRITE state; otherwise, the bus is tri-stated.
  -----------------------------------------------------------------------------
  sdram_dq <= data_reg((BURST_LENGTH - wait_counter) * SDRAM_DATA_WIDTH - 1 downto
                       (BURST_LENGTH - wait_counter - 1) * SDRAM_DATA_WIDTH)
             when state = WRITE else (others => 'Z');

  -----------------------------------------------------------------------------
  -- Data mask signals: Currently not used (set to '0' to disable masking).
  -----------------------------------------------------------------------------
  sdram_dqmh <= '0';
  sdram_dqml <= '0';

end architecture arch;

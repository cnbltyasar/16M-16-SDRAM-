# SDRAM Controller Overview
This SDRAM controller is written in VHDL and provides a 32-bit synchronous interface to a 16M×16 SDRAM chip. It handles both read and write operations, converting the 32-bit controller address and data into the 16-bit format required by the SDRAM. The design is configurable via several generics (parameters), allowing you to adapt it to different clock frequencies and SDRAM timing requirements.

1. Entity and Generics
Entity Ports
Reset and Clock

reset: Initializes the controller.
clk: Drives the synchronous logic of the controller.
Address and Data Buses

addr: 32-bit address input. Internally, this address is converted to the 16-bit SDRAM format.
data: 32-bit data input for write operations.
Control Signals

we (Write Enable): Indicates when a write operation should occur.
req (Request): Triggers a memory access operation.
ack (Acknowledge): Asserted by the controller to signal that a request has been accepted.
valid: Asserted when a read operation has completed and the output data (q) is valid.
SDRAM Interface Signals

sdram_a: SDRAM address lines.
sdram_ba: SDRAM bank select lines.
sdram_dq: Bidirectional data bus for the SDRAM.
sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n: SDRAM control signals (all active low).
Generics (Parameters)
Clock Frequency and Timings

CLK_FREQ: The operating frequency of the controller (in MHz).
Timing parameters (in nanoseconds) include:
Startup delay (T_DESL)
Mode register delay (T_MRD)
Row cycle time (T_RC)
RAS-to-CAS delay (T_RCD)
Precharge delay (T_RP)
Write recovery time (T_WR)
Refresh interval (T_REFI)
These values are converted internally to clock cycle counts.

Data and Address Widths

Parameters for both the external (32-bit) and internal (16-bit for SDRAM) interfaces.
Other SDRAM Settings

Burst Length (BURST_LENGTH): The number of SDRAM words to be read/written in one burst.
CAS Latency (CAS_LATENCY): Delay between issuing a read command and data availability.
2. Internal Signals and Constants
SDRAM Commands
The controller defines several 4-bit command constants that correspond to the SDRAM commands:

CMD_ACTIVE: Activates a row.
CMD_READ: Initiates a read operation.
CMD_WRITE: Initiates a write operation.
CMD_PRECHARGE, CMD_AUTO_REFRESH, CMD_LOAD_MODE, etc.
These commands are applied to the SDRAM control lines to perform the corresponding operations.

Timing Calculations
Based on the provided nanosecond parameters and the clock frequency, the design calculates:

INIT_WAIT: Clock cycles to wait after power-up before starting initialization.
LOAD_MODE_WAIT, ACTIVE_WAIT, REFRESH_WAIT, PRECHARGE_WAIT: Minimum wait cycles required for various SDRAM operations.
Mode Register Setup
The SDRAM mode register is configured with:

Burst length
Burst type (sequential or interleaved)
CAS latency
Write burst mode
This is done by combining these settings into a constant (MODE_REG) that is sent to the SDRAM during initialization.

3. Finite State Machine (FSM)
The core of the controller is its FSM, which steps through the following states:

INIT (Initialization)
Purpose: Prepare the SDRAM for operation.
Steps:
Deselect: Initially, the SDRAM is not selected.
Precharge: All rows are precharged.
Auto-Refresh: Issue a couple of refresh commands to stabilize the memory.
Transition: After completing these steps, the FSM moves to the MODE state.
MODE (Load Mode Register)
Purpose: Configure the SDRAM with the correct operating parameters.
Action: Sends a CMD_LOAD_MODE command with the precomputed mode register value.
Transition: When the operation is complete, the FSM goes to the IDLE state.
IDLE (Wait for Request)
Purpose: Wait for an external memory access request or a refresh requirement.
Actions:
If a refresh is needed (tracked by a refresh counter), transition to the REFRESH state.
If a read/write request (req) is received, transition to the ACTIVE state.
ACTIVE (Row Activation)
Purpose: Open the specific row in SDRAM where the data will be read or written.
Action: Sends a CMD_ACTIVE command to activate the target row.
Transition: Once the row is active (after a wait period defined by ACTIVE_WAIT), move to:
READ state if it’s a read operation.
WRITE state if it’s a write operation.
READ/WRITE States
READ
Action:
Sends a CMD_READ command (often with an auto-precharge flag) to initiate the data burst.
Reads data in two 16-bit parts to form a full 32-bit word.
Timing: Uses signals (first_word and read_done) to manage data capture.
Transition: After reading:
If a refresh is needed, move to the REFRESH state.
Otherwise, return to the IDLE state.
WRITE
Action:
Sends a CMD_WRITE command.
Breaks the 32-bit input data into two 16-bit chunks for writing.
Timing: Uses a write_done signal to enforce the proper timing before completing the write operation.
Transition: After writing, similar to the read state:
Transition to REFRESH if needed.
Otherwise, return to the IDLE state.
REFRESH (Auto Refresh)
Purpose: Periodically refresh the SDRAM to prevent data loss.
Action: When the refresh counter reaches its threshold, issue a CMD_AUTO_REFRESH command.
Transition: Once the refresh is complete (after the required wait period), return to either:
IDLE if no new request is pending.
ACTIVE if a new request is waiting.
4. Supporting Counters and Timing
Wait Counter
Usage: Ensures that each state is held for the minimum number of clock cycles required by the SDRAM’s timing specifications.
Example: After issuing an ACTIVE command, the controller waits for ACTIVE_WAIT cycles before proceeding.
Refresh Counter
Usage: Continuously increments during normal operation.
Purpose: Triggers an SDRAM refresh when the refresh interval is reached.
Reset: The counter resets after a refresh operation is completed.
5. Data Handling
Address Latching
Process: When a new access request starts (indicated by the start signal), the external 32-bit address is captured in an internal register (addr_reg).
Conversion: The address is shifted (multiplied by 2) to convert it from a 32-bit controller address to a 16-bit SDRAM address.
Read Data Latching
Process:
During a read, the SDRAM outputs 16 bits at a time.
The controller captures the first 16 bits into the upper half of a 32-bit register.
Later, when read_done is asserted, it captures the second 16 bits into the lower half.
Output: Once both halves are captured, the valid signal is asserted, indicating that the complete 32-bit word is ready.
Write Data Selection
Process: For a write operation, the controller selects the appropriate 16-bit portion of the 32-bit data (stored in data_reg).
Output: The selected 16-bit data is driven onto the SDRAM data bus at the correct time during the burst operation.

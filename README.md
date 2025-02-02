# SDRAM Controller Overview
This SDRAM controller is written in VHDL and provides a 32-bit synchronous interface to a 16M×16 SDRAM chip. It handles both read and write operations by converting the 32-bit controller address and data into the 16-bit format required by the SDRAM. The design is configurable via several generics (parameters), allowing you to adapt it to different clock frequencies and SDRAM timing requirements.

1. Entity and Generics
Entity Ports
Reset and Clock
Signal	Description
reset	Initializes the controller.
clk	Drives the synchronous logic of the controller.
Address and Data Buses
Signal	Description
addr	32-bit address input. Internally converted to the 16-bit SDRAM format.
data	32-bit data input for write operations.
Control Signals
Signal	Description
we	Write Enable – indicates when a write operation should occur.
req	Request – triggers a memory access operation.
ack	Acknowledge – asserted by the controller to signal that a request has been accepted.
valid	Asserted when a read operation has completed and the output data (q) is valid.
SDRAM Interface Signals
Signal	Description
sdram_a	SDRAM address lines.
sdram_ba	SDRAM bank select lines.
sdram_dq	Bidirectional data bus for the SDRAM.
sdram_cke, sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n	SDRAM control signals (all active low).
Generics (Parameters)
Clock Frequency and Timings
CLK_FREQ: Operating frequency (in MHz).
Timing Parameters (in ns):
T_DESL: Startup delay.
T_MRD: Mode register delay.
T_RC: Row cycle time.
T_RCD: RAS-to-CAS delay.
T_RP: Precharge delay.
T_WR: Write recovery time.
T_REFI: Refresh interval.
Note: These values are converted internally into clock cycle counts.

Data and Address Widths
Parameters for both the external (32-bit) and internal (16-bit for SDRAM) interfaces.
Other SDRAM Settings
BURST_LENGTH: Number of SDRAM words to be read/written in one burst.
CAS_LATENCY: Delay between issuing a read command and data availability.
2. Internal Signals and Constants
SDRAM Commands
The controller defines several 4-bit command constants that correspond to the SDRAM commands. Examples include:

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
The SDRAM mode register is configured with the following settings:

Burst Length
Burst Type (sequential or interleaved)
CAS Latency
Write Burst Mode
These settings are combined into a constant (MODE_REG) that is sent to the SDRAM during initialization.

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
Transition: The FSM goes to the IDLE state when the operation is complete.
IDLE (Wait for Request)
Purpose: Wait for an external memory access request or a refresh requirement.
Actions:
Transition to REFRESH if a refresh is needed (tracked by a refresh counter).
Transition to ACTIVE if a read/write request (req) is received.
ACTIVE (Row Activation)
Purpose: Open the specific row in SDRAM where the data will be read or written.
Action: Sends a CMD_ACTIVE command to activate the target row.
Transition: After the wait period defined by ACTIVE_WAIT, move to:
READ state for a read operation.
WRITE state for a write operation.
READ/WRITE States
READ
Action:
Sends a CMD_READ command (often with an auto-precharge flag) to initiate the data burst.
Reads data in two 16-bit parts to form a full 32-bit word.
Timing: Managed by signals such as first_word and read_done.
Transition: After reading:
Move to REFRESH if a refresh is needed.
Otherwise, return to IDLE.
WRITE
Action:
Sends a CMD_WRITE command.
Breaks the 32-bit input data into two 16-bit chunks for writing.
Timing: Enforced by a write_done signal.
Transition: After writing:
Transition to REFRESH if needed.
Otherwise, return to IDLE.
REFRESH (Auto Refresh)
Purpose: Periodically refresh the SDRAM to prevent data loss.
Action: When the refresh counter reaches its threshold, issue a CMD_AUTO_REFRESH command.
Transition: Once the refresh is complete (after the required wait period), return to:
IDLE if no new request is pending.
ACTIVE if a new request is waiting.

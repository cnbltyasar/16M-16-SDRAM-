# SDRAM Controller Overview
This SDRAM controller is written in VHDL and provides a 32-bit synchronous interface to a 16M×16 SDRAM chip. It handles both read and write operations by converting the 32-bit controller address and data into the 16-bit format required by the SDRAM. The design is configurable via several generics (parameters), allowing you to adapt it to different clock frequencies and SDRAM timing requirements.
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>SDRAM Controller Documentation</title>
  <style>
    body {
      font-family: Arial, sans-serif;
      line-height: 1.6;
      margin: 20px;
    }
    h1, h2, h3, h4 {
      color: #333;
    }
    table {
      border-collapse: collapse;
      width: 100%;
      margin-bottom: 20px;
    }
    table, th, td {
      border: 1px solid #ccc;
    }
    th, td {
      padding: 8px;
      text-align: left;
    }
    code {
      background-color: #f4f4f4;
      padding: 2px 4px;
      border-radius: 3px;
    }
    hr {
      margin: 30px 0;
    }
  </style>
</head>
<body>
  <h1>SDRAM Controller Overview</h1>
  <p>This SDRAM controller is written in VHDL and provides a 32-bit synchronous interface to a 16M×16 SDRAM chip. It handles both read and write operations by converting the 32-bit controller address and data into the 16-bit format required by the SDRAM. The design is configurable via several generics (parameters), allowing you to adapt it to different clock frequencies and SDRAM timing requirements.</p>

  <hr>

  <h2>1. Entity and Generics</h2>

  <h3>Entity Ports</h3>

  <h4>Reset and Clock</h4>
  <table>
    <tr>
      <th>Signal</th>
      <th>Description</th>
    </tr>
    <tr>
      <td><code>reset</code></td>
      <td>Initializes the controller.</td>
    </tr>
    <tr>
      <td><code>clk</code></td>
      <td>Drives the synchronous logic of the controller.</td>
    </tr>
  </table>

  <h4>Address and Data Buses</h4>
  <table>
    <tr>
      <th>Signal</th>
      <th>Description</th>
    </tr>
    <tr>
      <td><code>addr</code></td>
      <td>32-bit address input. Internally converted to the 16-bit SDRAM format.</td>
    </tr>
    <tr>
      <td><code>data</code></td>
      <td>32-bit data input for write operations.</td>
    </tr>
  </table>

  <h4>Control Signals</h4>
  <table>
    <tr>
      <th>Signal</th>
      <th>Description</th>
    </tr>
    <tr>
      <td><code>we</code></td>
      <td>Write Enable – indicates when a write operation should occur.</td>
    </tr>
    <tr>
      <td><code>req</code></td>
      <td>Request – triggers a memory access operation.</td>
    </tr>
    <tr>
      <td><code>ack</code></td>
      <td>Acknowledge – asserted by the controller to signal that a request has been accepted.</td>
    </tr>
    <tr>
      <td><code>valid</code></td>
      <td>Asserted when a read operation has completed and the output data (<code>q</code>) is valid.</td>
    </tr>
  </table>

  <h4>SDRAM Interface Signals</h4>
  <table>
    <tr>
      <th>Signal</th>
      <th>Description</th>
    </tr>
    <tr>
      <td><code>sdram_a</code></td>
      <td>SDRAM address lines.</td>
    </tr>
    <tr>
      <td><code>sdram_ba</code></td>
      <td>SDRAM bank select lines.</td>
    </tr>
    <tr>
      <td><code>sdram_dq</code></td>
      <td>Bidirectional data bus for the SDRAM.</td>
    </tr>
    <tr>
      <td><code>sdram_cke</code>, <code>sdram_cs_n</code>, <code>sdram_ras_n</code>, <code>sdram_cas_n</code>, <code>sdram_we_n</code></td>
      <td>SDRAM control signals (all active low).</td>
    </tr>
  </table>

  <h3>Generics (Parameters)</h3>

  <h4>Clock Frequency and Timings</h4>
  <ul>
    <li><code>CLK_FREQ</code>: Operating frequency (in MHz).</li>
    <li>Timing parameters (in ns):
      <ul>
        <li><code>T_DESL</code>: Startup delay.</li>
        <li><code>T_MRD</code>: Mode register delay.</li>
        <li><code>T_RC</code>: Row cycle time.</li>
        <li><code>T_RCD</code>: RAS-to-CAS delay.</li>
        <li><code>T_RP</code>: Precharge delay.</li>
        <li><code>T_WR</code>: Write recovery time.</li>
        <li><code>T_REFI</code>: Refresh interval.</li>
      </ul>
    </li>
  </ul>
  <p><em>Note:</em> These values are converted internally into clock cycle counts.</p>

  <h4>Data and Address Widths</h4>
  <p>Parameters for both the external (32-bit) and internal (16-bit for SDRAM) interfaces.</p>

  <h4>Other SDRAM Settings</h4>
  <ul>
    <li><code>BURST_LENGTH</code>: Number of SDRAM words to be read/written in one burst.</li>
    <li><code>CAS_LATENCY</code>: Delay between issuing a read command and data availability.</li>
  </ul>

  <hr>

  <h2>2. Internal Signals and Constants</h2>

  <h3>SDRAM Commands</h3>
  <p>The controller defines several 4-bit command constants that correspond to the SDRAM commands. Examples include:</p>
  <ul>
    <li><strong>CMD_ACTIVE</strong>: Activates a row.</li>
    <li><strong>CMD_READ</strong>: Initiates a read operation.</li>
    <li><strong>CMD_WRITE</strong>: Initiates a write operation.</li>
    <li><strong>CMD_PRECHARGE</strong>, <strong>CMD_AUTO_REFRESH</strong>, <strong>CMD_LOAD_MODE</strong>, etc.</li>
  </ul>
  <p><em>These commands are applied to the SDRAM control lines to perform the corresponding operations.</em></p>

  <h3>Timing Calculations</h3>
  <p>Based on the provided nanosecond parameters and the clock frequency, the design calculates:</p>
  <ul>
    <li><code>INIT_WAIT</code>: Clock cycles to wait after power-up before starting initialization.</li>
    <li><code>LOAD_MODE_WAIT</code>, <code>ACTIVE_WAIT</code>, <code>REFRESH_WAIT</code>, <code>PRECHARGE_WAIT</code>: Minimum wait cycles required for various SDRAM operations.</li>
  </ul>

  <h3>Mode Register Setup</h3>
  <p>The SDRAM mode register is configured with the following settings:</p>
  <ul>
    <li>Burst Length</li>
    <li>Burst Type (sequential or interleaved)</li>
    <li>CAS Latency</li>
    <li>Write Burst Mode</li>
  </ul>
  <p>These settings are combined into a constant (<code>MODE_REG</code>) that is sent to the SDRAM during initialization.</p>

  <hr>

  <h2>3. Finite State Machine (FSM)</h2>
  <p>The core of the controller is its FSM, which steps through the following states:</p>

  <h3>INIT (Initialization)</h3>
  <ul>
    <li><strong>Purpose:</strong> Prepare the SDRAM for operation.</li>
    <li><strong>Steps:</strong>
      <ul>
        <li><em>Deselect:</em> Initially, the SDRAM is not selected.</li>
        <li><em>Precharge:</em> All rows are precharged.</li>
        <li><em>Auto-Refresh:</em> Issue a couple of refresh commands to stabilize the memory.</li>
      </ul>
    </li>
    <li><strong>Transition:</strong> After completing these steps, the FSM moves to the <strong>MODE</strong> state.</li>
  </ul>

  <h3>MODE (Load Mode Register)</h3>
  <ul>
    <li><strong>Purpose:</strong> Configure the SDRAM with the correct operating parameters.</li>
    <li><strong>Action:</strong> Sends a <code>CMD_LOAD_MODE</code> command with the precomputed mode register value.</li>
    <li><strong>Transition:</strong> When the operation is complete, the FSM goes to the <strong>IDLE</strong> state.</li>
  </ul>

  <h3>IDLE (Wait for Request)</h3>
  <ul>
    <li><strong>Purpose:</strong> Wait for an external memory access request or a refresh requirement.</li>
    <li><strong>Actions:</strong>
      <ul>
        <li>If a refresh is needed (tracked by a refresh counter), transition to the <strong>REFRESH</strong> state.</li>
        <li>If a read/write request (<code>req</code>) is received, transition to the <strong>ACTIVE</strong> state.</li>
      </ul>
    </li>
  </ul>

  <h3>ACTIVE (Row Activation)</h3>
  <ul>
    <li><strong>Purpose:</strong> Open the specific row in SDRAM where the data will be read or written.</li>
    <li><strong>Action:</strong> Sends a <code>CMD_ACTIVE</code> command to activate the target row.</li>
    <li><strong>Transition:</strong> After the wait period defined by <code>ACTIVE_WAIT</code>, move to:
      <ul>
        <li><strong>READ</strong> state for a read operation.</li>
        <li><strong>WRITE</strong> state for a write operation.</li>
      </ul>
    </li>
  </ul>

  <h3>READ/WRITE States</h3>

  <h4>READ</h4>
  <ul>
    <li><strong>Action:</strong> Sends a <code>CMD_READ</code> command (often with an auto-precharge flag) to initiate the data burst.</li>
    <li><strong>Reads:</strong> Data in two 16-bit parts to form a full 32-bit word.</li>
    <li><strong>Timing:</strong> Managed by signals such as <code>first_word</code> and <code>read_done</code>.</li>
    <li><strong>Transition:</strong> After reading:
      <ul>
        <li>Move to <strong>REFRESH</strong> if a refresh is needed.</li>
        <li>Otherwise, return to <strong>IDLE</strong>.</li>
      </ul>
    </li>
  </ul>

  <h4>WRITE</h4>
  <ul>
    <li><strong>Action:</strong> Sends a <code>CMD_WRITE</code> command.</li>
    <li><strong>Operation:</strong> Breaks the 32-bit input data into two 16-bit chunks for writing.</li>
    <li><strong>Timing:</strong> Enforced by a <code>write_done</code> signal.</li>
    <li><strong>Transition:</strong> After writing:
      <ul>
        <li>Transition to <strong>REFRESH</strong> if needed.</li>
        <li>Otherwise, return to <strong>IDLE</strong>.</li>
      </ul>
    </li>
  </ul>

  <h3>REFRESH (Auto Refresh)</h3>
  <ul>
    <li><strong>Purpose:</strong> Periodically refresh the SDRAM to prevent data loss.</li>
    <li><strong>Action:</strong> When the refresh counter reaches its threshold, issue a <code>CMD_AUTO_REFRESH</code> command.</li>
    <li><strong>Transition:</strong> Once the refresh is complete (after the required wait period), return to:
      <ul>
        <li><strong>IDLE</strong> if no new request is pending.</li>
        <li><strong>ACTIVE</strong> if a new request is waiting.</li>
      </ul>
    </li>
  </ul>

  <hr>

  <h2>4. Supporting Counters and Timing</h2>

  <h3>Wait Counter</h3>
  <ul>
    <li><strong>Usage:</strong> Ensures that each state is held for the minimum number of clock cycles as per SDRAM timing specifications.</li>
    <li><strong>Example:</strong> After issuing an ACTIVE command, the controller waits for <code>ACTIVE_WAIT</code> cycles before proceeding.</li>
  </ul>

  <h3>Refresh Counter</h3>
  <ul>
    <li><strong>Usage:</strong> Continuously increments during normal operation.</li>
    <li><strong>Purpose:</strong> Triggers an SDRAM refresh when the refresh interval is reached.</li>
    <li><strong>Reset:</strong> The counter resets after a refresh operation is completed.</li>
  </ul>

  <hr>

  <h2>5. Data Handling</h2>

  <h3>Address Latching</h3>
  <ul>
    <li><strong>Process:</strong> When a new access request starts (indicated by the <code>start</code> signal), the external 32-bit address is captured in an internal register (<code>addr_reg</code>).</li>
    <li><strong>Conversion:</strong> The address is shifted (multiplied by 2) to convert from a 32-bit controller address to a 16-bit SDRAM address.</li>
  </ul>

  <h3>Read Data Latching</h3>
  <ul>
    <li><strong>Process:</strong> During a read, the SDRAM outputs 16 bits at a time. The controller captures:</li>
    <ul>
      <li>The first 16 bits into the upper half of a 32-bit register.</li>
      <li>Later, when <code>read_done</code> is asserted, the second 16 bits into the lower half.</li>
    </ul>
    <li><strong>Output:</strong> Once both halves are captured, the <code>valid</code> signal is asserted, indicating that the complete 32-bit word is ready.</li>
  </ul>

  <h3>Write Data Selection</h3>
  <ul>
    <li><strong>Process:</strong> For a write operation, the controller selects the appropriate 16-bit portion of the 32-bit data (stored in <code>data_reg</code>).</li>
    <li><strong>Output:</strong> The selected 16-bit data is driven onto the SDRAM data bus at the correct time during the burst operation.</li>
  </ul>

  <hr>

  <h2>Conclusion</h2>
  <p>This SDRAM controller works by:</p>
  <ul>
    <li><strong>Initializing</strong> the SDRAM with a specific power-up sequence.</li>
    <li><strong>Waiting in an IDLE state</strong> until a read or write request is made.</li>
    <li><strong>Activating the correct SDRAM row</strong> before any data access.</li>
    <li><strong>Executing read/write operations</strong> as bursts of two 16-bit transfers (to handle a full 32-bit word).</li>
    <li><strong>Handling periodic refresh cycles</strong> to maintain data integrity.</li>
  </ul>
  <p>By abstracting these low-level details, the controller allows a higher-level system to perform memory accesses using simple request/acknowledge signaling without dealing with the intricate SDRAM timing and command sequences.</p>
  <p>Feel free to customize and expand upon this explanation as needed for your project documentation!</p>
</body>
</html>


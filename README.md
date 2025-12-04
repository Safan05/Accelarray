Accelarray: Domain Specific Convolution Accelerator

<div align="center">
<img src="https://github.com/user-attachments/assets/689372a6-bc5f-4e76-9031-e4b1aa7d8237" alt="Accelarray Architecture" width="800"/>
</div>

🚀 Overview

Accelarray is a high-performance hardware accelerator designed specifically for efficient 2D convolution operations, a core computation in deep learning and image processing workloads.

Built as a streaming coprocessor for the CMP3020 VLSI course at CUFE, it utilizes an $8 \times 8$ Systolic Array architecture to maximize throughput and energy efficiency. The design features a Weight Stationary (WS) dataflow to minimize expensive memory accesses, a sophisticated Address Generation Unit (AGU) for complex tiling, and a robust SRAM subsystem with Ping-Pong buffering.

👥 The Team

| Division              | Members                           |
| --------------------- | --------------------------------- |
| **Systolic Array**    | Abdallah Safan, Ahmed Kamal       |
| **Control Unit**      | Mohamed Abdelazin, Abdallah Ayman |
| **Data Loader & AGU** | Esraa, Amira                      |
| **SRAM Subsystem**    | Hagar Abdelsalam, Alyaa Ali       |

⚙️ Core Architecture

Systolic Array: 8 × 8 (64 Processing Elements)

Dataflow: Weight-Stationary (weights stay fixed in PEs)

Arithmetic Precision:

Inputs / Weights: 8-bit unsigned

Accumulation: 32-bit

Input Support: Up to 64 × 64 via hardware tiling

Kernel Support: 2 × 2 → 16 × 16 via kernel tiling

Memory: On-chip SRAM with Ping-Pong (double) buffering

🏗️ Architecture Modules

1️⃣ Systolic Array (Compute Core)

  Fully pipelined MAC units

  Clock gating for power efficiency

Dataflow:

  Pixels flow West → East

  Partial sums flow North → South

2️⃣ Data Loader & AGU (Address Generation Unit)

  2D (x,y) → 1D address mapping

  Sliding window read patterns with halo support

  Hardware tiling into 10 × 10 tiles

  Automatic management of overlaps

3️⃣ Control Unit

  Global FSM orchestration

  AXI-Stream-like Valid/Ready handshake

  Manages Ping-Pong buffer swapping

4️⃣ SRAM Subsystem

  High-speed intermediate storage

  Multi-bank simultaneous read/write

  Holds input feature maps, kernels, and outputs

⚡ Key Features
🔷 Smart Tiling

  Processes large images by breaking them into overlapping tiles that fit hardware limits.

🔷 Kernel Virtualization

  Supports large kernels (e.g., 16 × 16) via kernel tiling and partial accumulation.

🔷 Zero-Stall Operation

  Ping-Pong double buffering ensures continuous data feeding → maximum throughput and no idle cycles.

<div align="center">
✨ Built with ❤️ by the Accelarray Team

CUFE CMP Class of 2027

</div>

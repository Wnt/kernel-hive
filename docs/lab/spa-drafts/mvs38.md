# Exhibit draft — IBM MVS 3.8j mainframe

> Prep branch: `mvs38` · tracking issue: #49  
> Intended destination: `registry/posters/mvs38.md`.  
> Final paragraph should name the chosen turnkey environment and exact emulated System/370 model after the smoke rig is fixed.

---
title: IBM MVS 3.8j — the mainframe behind the green screen
subtitle: 1970s · IBM System/370 · batch jobs, TSO and a 3270 terminal
hero: /posters/mvs38/desktop.webp
images:
  - src: /posters/mvs38/desktop.webp
    alt: An IBM 3270-style green-screen terminal showing a formatted TSO or ISPF panel connected to an MVS 3.8j mainframe
    caption: The computer is not the terminal. The terminal is a window into a shared mainframe running many users and jobs at once.
---

## Origins

IBM's mainframe operating-system line did not begin with MVS. It began with the enormous **System/360** project of the 1960s, where one architecture was meant to cover machines from small commercial systems to large scientific installations. Its operating systems evolved through OS/360, MVT and SVS into **MVS — Multiple Virtual Storage**.

MVS made virtual memory central to the way the system was divided among jobs and users. By the late 1970s, MVS was the environment behind a large share of institutional computing: banks, governments, universities and large companies ran work that was submitted in batches, operated from terminals, or scheduled to run without a person watching it.

The release used here, **MVS 3.8j**, is old enough to expose that world directly rather than through a modern compatibility layer.

## Significance

A mainframe changes the unit of computing. The exhibit is not “a person owns a computer.” The computer is a shared service, and the person gets a session, a job, a dataset and an allocation of resources.

That is why the interface looks so different. **JCL** describes batch work rather than behaving like an interactive shell script. **TSO** gives a user an interactive session. A **3270** terminal does not send every keystroke like a teletype; it works with formatted fields and sends blocks of input back to the host. The screen itself therefore behaves differently from a Unix terminal even when both are green text.

This is also the missing IBM branch in the museum. The collection already shows DEC minicomputers, workstations and personal computers. MVS shows the scale above them: the centralized machine those smaller systems were often replacing, connecting to, or rebelling against.

## What you're looking at

The visitor-facing surface should be a full-screen **3270 terminal** connected to the emulated MVS system, ideally resting at a TSO or ISPF screen. The Hercules operator console belongs backstage; it is machinery, not the exhibit.

A useful first interaction is deliberately small: log on, move through one formatted panel, inspect a dataset or submit a tiny batch job. The point is to feel the block-mode terminal and the distinction between an interactive session and scheduled work.

The final poster should name the exact Hercules machine configuration, memory and turnkey distribution only after they are fixed by the integration wave.

## Legacy

MVS did not simply vanish when minicomputers and PCs arrived. Its descendants became OS/390 and then **z/OS**, and IBM mainframes remain in production today.

That continuity is part of the exhibit's value. Many systems in this museum are dead branches whose ideas survived elsewhere. MVS is different: the lineage is still alive, and the old green-screen vocabulary remains recognizable inside a platform that has been continuously rebuilt for half a century.

## Sources

- Hercules emulator: https://www.hercules-390.eu/
- TK5/Hercules turnkey environment: https://github.com/joergschultzelutter/tk5-hercules
- Kernel Hive media research: `docs/catalog/os-media-catalog.md`

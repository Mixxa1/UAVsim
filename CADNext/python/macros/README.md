# CADNext Python Macros

This folder will contain user macros and automation scripts built on top of the CADNext Python wrappers.

Initial rules:

- keep critical geometry operations in C++;
- call wrapped C++ APIs from Python;
- do not depend on DroneUAVDemo Swift types;
- use bridge exports when a model must move into UAVsim.

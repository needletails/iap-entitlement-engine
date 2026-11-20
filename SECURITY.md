# Security policy

## Supported versions

Security fixes are released for the latest 1.x version.

## Reporting a problem

Please do not open a public issue for a security problem.

Email [support@needletails.com](mailto:support@needletails.com). Say what you found, how to reproduce it, and which version you used.

We aim to reply within five working days, and will tell you when a fix is released.

## What this package trusts

The engine does not verify store data. Your server has to verify Apple's signatures, and fetch Google purchases itself, before it calls the engine. A problem that needs unverified data to reach the engine is a problem in the caller, but we still want to hear about anything in this package that makes that mistake easy.

# Installation instructions

# Quick instructions

On an up-to-date system with gfortran, simply do:

    $ git clone https://gitlab.com/MD-CWI-NL/afivo.git
    $ cd afivo
    $ make

With `make -j 4` the build is done in parallel, using four processors. If you
want to compile with runtime checks (useful for debugging) and profiling
options, then do:

    $ make clean
    $ make DEBUG=1

## Requirements

* Fortran 2008 compatible compiler (gfortran >= 4.8 has been tested)
* C/C++ compiler for compiling Silo (see below).

A recent version of the Intel compiler ifort *should* in also work. You can try
this with

    $ make COMPILER=ifort

## Dependencies

Afivo has one dependency: Silo. The script `external_libraries/build_silo.sh`
automatically downloads, configures and compiles Silo into your Afivo directory.
If this fails, then you should probably download, configure and install Silo
yourself. If you really do not want to use Silo (Afivo also supports .vtu
output), you could remove the Silo routines.
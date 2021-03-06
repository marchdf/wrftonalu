# WRF to Nalu converter

This program converts WRF data to
the [Nalu](https://github.com/NaluCFD/Nalu) (Exodus II) data
format. Exodus II is part of [SEACAS](gsjaardema.github.io/seacas) and
one can find other utilities to work with Exodus II files there. The
objective is to provide Nalu with input WRF data as boundary
conditions.

This program was started as WRFTOOF, a WRF to OpenFoam converter,
which was written by J. Michalakes and M. Churchfield. It was adapted
for converting to Nalu data by M. T. Henry de Frahan.

## Building

The code will compile and run with either gfortran or ifort and needs
to have the path to the NetCDF library and include files specified in
the [Makefile](Makefile). To work with netCDF-4 files, I recommend
building netCDF with netCDF-4 and HDF5 enabled. The easiest way to do
so (and completely compatible with the Makefile included here), is to
use[Spack](https://github.com/LLNL/spack):
```{bash}
spack install netcdf-fortran %intel
```
You can do the same with `gcc` instead of `intel` if you want to.


On Peregrine, you would set up the build environment and build as:
```{bash}
module purge
module load python/2.7.8 compiler/intel/16.0.2
spack load netcdf-fortran
make
```

## Documentation

This is done through doxygen and can be generated by doing:

```{bash}
make doc
```

## Running

```{bash}
./wrftonalu wrfout
```
where `wrfout` is the WRF data file. This will generate Exodus
boundary condition files for Nalu. The Exodus mesh files it needs to
do this should be in the run directory and named `west.g`, `east.g`,
`south.g`, `north.g`, `lower.g`, and `upper.g` (any, all or none of
those files can exist). The ouput will be `west.nc`, `east.nc`,
`south.nc`, `north.nc`, `lower.nc`, and `upper.nc` files containing
the interpolated WRF data on the Exodus mesh for input into Nalu.

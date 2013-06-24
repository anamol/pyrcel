#cython: embedsignature:True
#cython: profile=True
#cython: boundscheck=False
#cython: cdivision=True
# (embedsignature adds doc-strings accessible by Sphinx)
"""
.. module:: parcel
    :synopsis: Parcel model derivative calculations in Cython for speedup.

.. moduleauthor:: Daniel Rothenberg <darothen@mit.edu>

"""

from cython.parallel cimport prange, parallel
from libc.math cimport exp, sqrt

import numpy as np
cimport numpy as np
cimport cython
cimport openmp

## Thermodynamic/chemistry constants
cdef:
    double Mw = 18.0153/1e3 #: Molecular weight of water, kg/mol
    double Ma = 28.9/1e3    #: Molecular weight of dry air, kg/mol
    double R = 8.314        #: Universal gas constant, J/(mol K)
    double rho_w = 1e3      #: Density of water, kg/m**3
    double Rd = 287.0       #: Gas constant for dry air, J/(kg K)
    double g = 9.81         #: Gravitational constant, m/s**2
    double Dv = 3.e-5       #: Diffusivity of water vapor in air, m^2/s
    double ac = 1.0         #: Condensation Constant
    double Ka = 2.e-2       #: Thermal conductivity of air, J/m/s/K
    double at = 0.96        #: thermal accomodation coefficient
    double L = 2.5e6        #: Latent heat of condensation, J/kg
    double Cp = 1004.0      #: Specific heat of dry air at constant pressure, J/kg
    double PI = 3.14159265358979323846264338328 # Pi, constant

## Auxiliary, single-value calculations with GIL released for derivative
## calculations
cdef inline double sigma_w(double T) nogil:
    """See :func:`parcel_model.micro.sigma_w` for full documentation
    """
    return 0.0761 - (1.55e-4)*(T-273.15)

cdef inline double ka(double T, double r, double rho) nogil:
    """See :func:`parcel_model.micro.ka` for full documentation
    """
    cdef double denom, ka_cont
    ka_cont = 1e-3*(4.39 + 0.071*T)
    denom = 1.0 + (ka_cont/(at*r*rho*Cp))*sqrt((2*PI*Ma)/(R*T))
    return ka_cont/denom

cdef inline double dv(double T, double r, double P) nogil:
    """See :func:`parcel_model.micro.dv` for full documentation
    """
    cdef double denom, dv_cont, P_atm
    P_atm = P*1.01325e-5 # Pa -> atm
    dv_cont = 1e-4*(0.211/P_atm)*((T/273.)**1.94)
    denom = 1.0 + (dv_cont/(ac*r))*sqrt((2*PI*Mw)/(R*T))
    return dv_cont/denom

cdef inline double es(double T):
    """See :func:`parcel_model.micro.es` for full documentation
    """
    return 611.2*exp(17.67*T/(T+243.5))

cdef double Seq(double r, double r_dry, double T, double kappa) nogil:
    """See :func:`parcel_model.micro.Seq` for full documentation.
    """
    cdef double A = (2.*Mw*sigma_w(T))/(R*T*rho_w*r)
    cdef double B = 1.0
    if kappa > 0.0:
        B = (r**3 - (r_dry**3))/(r**3 - (r_dry**3)*(1.-kappa))
    cdef double returnval = exp(A)*B - 1.0
    return returnval

## RHS Derivative callback function
def der(np.ndarray[double, ndim=1] y, double t,
        int nr, np.ndarray[double, ndim=1] r_drys, np.ndarray[double, ndim=1] Nis,
        double V, np.ndarray[double, ndim=1] kappas):
    """ Calculates the instantaneous time-derivate of the parcel model system.

    Given a current state vector ``y`` of the parcel model, computes the tendency
    of each term including thermodynamic (pressure, temperature, etc) and aerosol
    terms. The basic aerosol properties used in the model must be passed along
    with the state vector (i.e. if being used as the callback function in an ODE
    solver).

    Args:
        y: NumPy array containing the current state of the parcel model system,
            * y[0] = pressure, Pa
            * y[1] = temperature, K
            * y[2] = water vapor mass mixing ratio, kg/kg
            * y[3] = droplet liquid water mass mixing ratio, kg/kg
            * y[3] = parcel supersaturation
            * y[nr:] = aerosol bin sizes (radii), m
        t: Current decimal model time
        nr: Integer number of aerosol radii being tracked
        r_drys: NumPy array with original aerosol dry radii, m
        Nis: NumPy array with aerosol number concentrations, m**-3
        V: Updraft velocity, m/s
        kappas: NumPy array containing all aerosol hygroscopicities

    Returns:
        A NumPy array with the same shape and term order as y, but containing
            all the computed tendencies at this time-step.

    .. note:: This calculation has been arranged to use a parallelized (via
        OpenMP) for-loop when possible. Setting the environmental variable
        **OMP_NUM_THREADS** to an integer greater than 1 will yield
        multi-threaded computations, but could invoke race conditions and cause
        slow-down if too many threads are specified.

    """
    cdef double P = y[0]
    cdef double T = y[1]
    cdef double wv = y[2]
    cdef double wc = y[3]
    cdef double S = y[4]
    cdef np.ndarray[double, ndim=1] rs = y[5:]

    cdef double T_c = T-273.15 # convert temperature to Celsius
    cdef double pv_sat = es(T_c) # saturation vapor pressure
    cdef double wv_sat = wv/(S+1.) # saturation mixing ratio
    cdef double Tv = (1.+0.61*wv)*T
    cdef double rho_air = P/(Rd*Tv)

    ## Begin computing tendencies

    cdef double dP_dt = (-g*P*V)/(Rd*Tv)

    cdef np.ndarray[double, ndim=1] drs_dt = np.empty(dtype="d", shape=(nr))
    cdef int i
    cdef double dwc_dt = 0.0

    cdef: # variables set in parallel loop
        double G_a, G_b, G
        double r, r_dry, delta_S, kappa, dr_dt, Ni
        double dv_r, ka_r, P_atm, A, B, Seq_r

    for i in prange(nr, nogil=True, schedule='static'):#, num_threads=40):
        r = rs[i]
        r_dry = r_drys[i]
        kappa = kappas[i]
        Ni = Nis[i]

        ## Non-continuum diffusivity/thermal conductivity of air near
        ## near particle
        dv_r = dv(T, r, P)
        ka_r = ka(T, r, rho_air)

        ## Condensation coefficient
        G_a = (rho_w*R*T)/(pv_sat*dv_r*Mw)
        G_b = (L*rho_w*((L*Mw/(R*T))-1.))/(ka_r*T)
        G = 1./(G_a + G_b)

        ## Difference between ambient and particle equilibrium supersaturation
        Seq_r = Seq(r, r_dry, T, kappa)
        delta_S = S - Seq_r

        ## Size and liquid water tendencies
        dr_dt = (G/r)*delta_S
        dwc_dt += Ni*(r**2)*dr_dt # Contribution to liq. water tendency due to growth
        drs_dt[i] = dr_dt
    dwc_dt *= (4.*PI*rho_w/rho_air) # Hydrated aerosol size -> water mass

    cdef double dwv_dt
    dwv_dt = -dwc_dt

    cdef double dT_dt
    dT_dt = -g*V/Cp - L*dwv_dt/Cp

    ''' Alternative methods for calculation supersaturation tendency
    # Used eq 12.28 from Pruppacher and Klett in stead of (9) from Nenes et al, 2001
    #cdef double S_a, S_b, S_c, dS_dt
    #cdef double S_b_old, S_c_old, dS_dt_old
    #S_a = (S+1.0)

    ## NENES (2001)
    #S_b_old = dT_dt*wv_sat*(17.67*243.5)/((243.5+(Tv-273.15))**2.)
    #S_c_old = (rho_air*g*V)*(wv_sat/P)*((0.622*L)/(Cp*Tv) - 1.0)
    #dS_dt_old = (1./wv_sat)*(dwv_dt - S_a*(S_b_old-S_c_old))

    ## PRUPPACHER (PK 1997)
    #S_b = dT_dt*0.622*L/(Rd*T**2.)
    #S_c = g*V/(Rd*T)
    #dS_dt = P*dwv_dt/(0.622*es(T-273.15)) - S_a*(S_b + S_c)

    ## SEINFELD (SP 1998)
    #S_b = L*Mw*dT_dt/(R*T**2.)
    #S_c = V*g*Ma/(R*T)
    #dS_dt = dwv_dt*(Ma*P)/(Mw*es(T-273.15)) - S_a*(S_b + S_c)
    '''

    ## GHAN (2011)
    cdef double alpha, gamma, dS_dt
    alpha = (g*Mw*L)/(Cp*R*(T**2)) - (g*Ma)/(R*T)
    gamma = (P*Ma)/(Mw*pv_sat) + (Mw*L*L)/(Cp*R*T*T)
    dS_dt = alpha*V - gamma*dwc_dt

    cdef np.ndarray[double, ndim=1] x = np.empty(dtype='d', shape=(nr+5))
    x[0] = dP_dt
    x[1] = dT_dt
    x[2] = dwv_dt
    x[3] = dwc_dt
    x[4] = dS_dt
    x[5:] = drs_dt[:]

    return x

#include "../src/cpp_macros.h"
!> \example particles_gravity_Xd.f90
!>
!> Toy example showing how to simulate gravitating particles
program particles_gravity_Xd
  use m_af_all

  implicit none

  integer            :: n
  integer, parameter :: box_size    = 8
  integer, parameter :: n_particles = 100*1000
  integer, parameter :: particles_per_cell = 100
  integer, parameter :: max_refinement_lvl = 7
  integer, parameter :: i_phi       = 1
  integer, parameter :: i_rho       = 2
  integer, parameter :: i_tmp       = 3
  integer, parameter :: i_f(NDIM)     = [(i_tmp+n, n=1,NDIM)]

  real(dp), parameter :: force_to_accel = 1.0_dp

  real(dp), parameter :: domain_len      = 1.0_dp
  real(dp), parameter :: mean_density    = 1.0_dp
  real(dp), parameter :: particle_weight = domain_len**NDIM / n_particles
  real(dp), parameter :: dr              = domain_len / box_size
  real(dp), parameter :: t_end           = 5.0_dp
  real(dp), parameter :: dt_output       = 5e-2_dp
  real(dp)            :: dt              = 1.0e-2_dp
  real(dp)            :: dt_prev

  real(dp), allocatable :: coordinates(:, :)
  real(dp), allocatable :: velocities(:, :)
  integer, allocatable  :: ids(:)
  real(dp), allocatable :: weights(:)

  integer             :: n_output
  type(af_t)         :: tree
  type(mg_t)        :: mg
  type(ref_info_t)    :: refine_info
  integer             :: id, ix_list(NDIM, 1)
  integer             :: nb_list(2*NDIM, 1)
  integer             :: count_rate, wc_start, wc_end
  character(len=100)  :: fname
  real(dp)            :: max_vel, time

  print *, "Running particles_gravity_" // DIMNAME // ""
  print *, "Number of threads", af_get_max_threads()

  ! Initialize tree
  call af_init(tree, & ! Tree to initialize
       box_size, &     ! A box contains box_size**DIM cells
       n_var_cell=i_f(NDIM), & ! Number of cell-centered variables
       n_var_face=0, & ! Number of face-centered variables
       dr=dr, &        ! Distance between cells on base level
       coarsen_to=2, &
#if NDIM == 2
       cc_names=["phi", "rho", "tmp", "fx ", "fy "] & ! Variable names
#elif NDIM == 3
       cc_names=["phi", "rho", "tmp", "fx ", "fy ", "fz "] & ! Variable names
#endif
       )

  ! Set up geometry
  id             = 1
  ix_list(:, id) = 1 ! Set index of box
  nb_list(:, id) = 1 ! Fully periodic

  mg%i_phi         =  i_phi    ! Solution variable
  mg%i_rhs         =  i_rho    ! Right-hand side variable
  mg%i_tmp         =  i_tmp    ! Variable for temporary space
  mg%sides_bc      => af_bc_neumann_zero ! Not used
  mg%subtract_mean =  .true.

  call mg_init_mg(mg)

  ! Create the base mesh, using the box indices and their neighbor information
  call af_set_base(tree, 1, ix_list, nb_list)

  ! Set default methods (boundary condition is not actually used due to
  ! periodicity)
  call af_set_cc_methods(tree, i_phi, af_bc_neumann_zero, af_gc_interp)
  call af_set_cc_methods(tree, i_rho, af_bc_neumann_zero, af_gc_interp)
  do n = 1, NDIM
     call af_set_cc_methods(tree, i_f(n), af_bc_neumann_zero, af_gc_interp)
  end do

  allocate(coordinates(NDIM, n_particles))
  allocate(velocities(NDIM, n_particles))
  allocate(weights(n_particles))
  allocate(ids(n_particles))

  call random_number(coordinates(:, :))
  call random_number(velocities(:, :))
  velocities(:, :) = 0.0_dp
  weights(:) = particle_weight

  do n = 1, 100
     call af_tree_clear_cc(tree, i_rho)
     call af_particles_to_grid(tree, i_rho, coordinates, weights, &
          n_particles, 1, ids)
     call af_adjust_refinement(tree, refine_routine, refine_info, 2)
     if (refine_info%n_add == 0) exit
  end do

  ! Compute initial gravitational potential
  call mg_fas_fmg(tree, mg, .false., .false.)
  call mg_fas_fmg(tree, mg, .false., .true.)

  time     = 0.0_dp
  n        = 0
  n_output = 0
  dt_prev  = dt

  call system_clock(wc_start, count_rate)
  do while (time < t_end)
     n = n + 1
     call push_particles(coordinates, velocities, n_particles, dt)

     ! Compute force
     call af_tree_clear_cc(tree, i_rho)
     call af_particles_to_grid(tree, i_rho, coordinates, weights, &
          n_particles, 1, ids)
     call af_loop_box(tree, subtract_mean_density)

     call mg_fas_vcycle(tree, mg, .false.)
     call mg_fas_vcycle(tree, mg, .true.)

     call af_loop_box(tree, compute_forces)
     call af_gc_tree(tree, i_f)

     call update_velocities(tree, coordinates, velocities, &
          ids, n_particles, dt)

     time    = time + dt
     max_vel = sqrt(maxval(sum(velocities**2, dim=1)))
     dt      = min(1.1 * dt_prev, dt_output, &
          0.5_dp * af_min_dr(tree) / max_vel)
     dt_prev = dt
     call compute_total_energy(tree, coordinates, velocities, &
          ids, n_particles)

     if (modulo(n, 5) == 0) then
        call af_adjust_refinement(tree, refine_routine, refine_info, 2)
     end if

     if (n_output * dt_output <= time) then
        call af_tree_clear_cc(tree, i_rho)
        call af_particles_to_grid(tree, i_rho, coordinates, weights, &
          n_particles, 1, ids)
        n_output = n_output + 1
        write(fname, "(A,I4.4)") "particles_gravity_" // DIMNAME // "_", n_output
        call af_write_silo(tree, fname, n_output, time, dir="output")
        print *, "Time", time, "n_cells", af_num_cells_used(tree)
     end if
  end do

  call system_clock(wc_end, count_rate)
  print *, "Total time: ", (wc_end-wc_start) / real(count_rate, dp), " seconds"

contains

  subroutine compute_total_energy(tree, x, v, ids, n_particles)
    type(af_t), intent(in) :: tree
    integer, intent(in)     :: n_particles
    real(dp), intent(in)    :: x(NDIM, n_particles)
    real(dp), intent(in)    :: v(NDIM, n_particles)
    integer, intent(in)     :: ids(n_particles)
    real(dp)                :: sum_ken, sum_phi, phi(1)
    integer                 :: n

    sum_ken = 0.0_dp
    sum_phi = 0.0_dp

    do n = 1, n_particles
       phi = af_interp1(tree, x(:, n), [i_phi], 1, ids(n))
       sum_ken = sum_ken + 0.5_dp * sum(v(:, n)**2)
       sum_phi = sum_phi + 0.5_dp * phi(1)
    end do
    print *, "sum energy", sum_ken, sum_phi, sum_ken+sum_phi
  end subroutine compute_total_energy

  subroutine push_particles(x, v, n_particles, dt)
    integer, intent(in)     :: n_particles
    real(dp), intent(inout) :: x(NDIM, n_particles)
    real(dp), intent(in)    :: v(NDIM, n_particles)
    real(dp), intent(in)    :: dt
    integer                 :: n

    !$omp parallel do
    do n = 1, n_particles
       x(:, n) = x(:, n) + dt * v(:, n)
       x(:, n) = modulo(x(:, n), domain_len)
    end do
    !$omp end parallel do
  end subroutine push_particles

  subroutine update_velocities(tree, x, v, ids, n_particles, dt)
    type(af_t), intent(in) :: tree
    integer, intent(in)     :: n_particles
    real(dp), intent(in)    :: x(NDIM, n_particles)
    real(dp), intent(inout) :: v(NDIM, n_particles)
    integer, intent(inout)  :: ids(:)
    real(dp), intent(in)    :: dt
    integer                 :: n
    real(dp)                :: a(NDIM)

    !$omp parallel do private(a)
    do n = 1, n_particles
       a = af_interp1(tree, x(:, n), i_f, &
            NDIM, ids(n))
       v(:, n) = v(:, n) + dt * a * force_to_accel
    end do
    !$omp end parallel do
  end subroutine update_velocities

  subroutine refine_routine(box, cell_flags)
    type(box_t), intent(in) :: box
    integer, intent(out)      :: cell_flags(DTIMES(box%n_cell))
    real(dp)                  :: rho_refine, rho_derefine
    integer                   :: nc

    nc           = box%n_cell
    rho_refine   = particles_per_cell * particle_weight / box%dr**NDIM
    rho_derefine = rho_refine / (2**NDIM * 4)

    where (box%cc(DTIMES(1:nc), i_rho) > rho_refine)
       cell_flags(DTIMES(:)) = af_do_ref
    elsewhere (box%cc(DTIMES(1:nc), i_rho) < rho_derefine)
       cell_flags(DTIMES(:)) = af_rm_ref
    elsewhere
       cell_flags(DTIMES(:)) = af_keep_ref
    end where

    if (box%lvl >= max_refinement_lvl) then
       where (cell_flags == af_do_ref)
          cell_flags = af_keep_ref
       end where
    end if

  end subroutine refine_routine

  subroutine compute_forces(box)
    type(box_t), intent(inout) :: box
    integer                      :: IJK, nc
    real(dp)                     :: fac

    nc  = box%n_cell
    fac = -0.5_dp / box%dr

    do KJI_DO(1, nc)
#if NDIM == 2
       box%cc(i, j, i_f(1)) = fac * &
            (box%cc(i+1, j, i_phi) - box%cc(i-1, j, i_phi))
       box%cc(i, j, i_f(2)) = fac * &
            (box%cc(i, j+1, i_phi) - box%cc(i, j-1, i_phi))
#elif NDIM == 3
       box%cc(i, j, k, i_f(1)) = fac * &
            (box%cc(i+1, j, k, i_phi) - box%cc(i-1, j, k, i_phi))
       box%cc(i, j, k, i_f(2)) = fac * &
            (box%cc(i, j+1, k, i_phi) - box%cc(i, j-1, k, i_phi))
       box%cc(i, j, k, i_f(3)) = fac * &
            (box%cc(i, j, k+1, i_phi) - box%cc(i, j, k-1, i_phi))
#endif
    end do; CLOSE_DO

  end subroutine compute_forces

  subroutine subtract_mean_density(box)
    type(box_t), intent(inout) :: box

    box%cc(DTIMES(:), i_rho) = box%cc(DTIMES(:), i_rho) - mean_density
  end subroutine subtract_mean_density

end program particles_gravity_Xd
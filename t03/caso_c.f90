program shield_1d
    !
    ! Programa para estimar la precisión y la figura de mérito (FOM) asociadas a
    ! la probabilidad de transmisión, reflexión y absorción de partículas
    ! que atraviesan un atenuador de una dimensión para dos casos diferentes.
    ! 
    ! mod_rng.f90, mod_scatt.f90 y mod_mfp.f90 no sufrieron modificaciones. Ambos son de (Doerner, 2019)
    !
    ! Para compilar ejecute: gfortran caso_c.f90 mod_rng.f90 mod_mfp.f90 mod_scatt.f90 -o caso_c.exe
    ! Para correr ejecute (Linux): ./caso_c.exe
    !                     (Windows): caso_c.exe
    !
    ! Autores: Jessica Hernández
    !          Daniel Ramirez
    !
    ! Basado en (Doerner, 2019)
    !
    use iso_fortran_env, only: int32, real64

    use mod_rng
    use mod_mfp
    use mod_scatt

implicit none

    ! Parametros geometricos
    integer(kind=int32), parameter :: nreg = 5              ! numero de regiones
    real(kind=real64), dimension(nreg) :: xthick = 1.0  ! grosor del atenuador 1D (cm)
    real(kind=real64), dimension(nreg+1) :: xbounds = 0.0   ! fronteras de la region (cm)

    ! Parametros de transporte
    real(kind=real64), dimension(nreg) :: sigma_t = 2.0  ! sección eficaz total de interaccion (cm-1)
    real(kind=real64), dimension(nreg) :: sigma_a = 0.0      ! Seccion eficaz de absorcion (cm-1)
    real(kind=real64), dimension(nreg) :: sigma_s = 0.0      ! Seccion eficaz de dispersion (cm-1)

    ! Parametros de la particula
    real(kind=real64), parameter :: xin = 0.0    ! posicion inicial (cm)
    real(kind=real64), parameter :: uin = 1.0    ! direccion inicial
    real(kind=real64), parameter :: wtin = 1.0   ! peso estadistico
    integer(kind=int32), parameter :: irin = 1   ! region inicial

    ! Now we introduce the concept of stack, therefore we expand each particle 
    ! parameter to a size of the stack.
    integer(kind=int32), parameter :: nstack = 100  ! maximum number of particles that can hold the stack
    integer(kind=int32) :: np
    integer(kind=int32), dimension(nstack) :: ir
    real(kind=real64), dimension(nstack) :: x, u, wt

    ! Geometrical splitting VRT parameters
    real(kind=real64) :: gs_r = 2.63                ! ratio of region importances.
    integer(kind=int32) :: gs_n                     ! integer part of gs_r
    real(kind=real64), dimension(nreg) :: gs_i      ! importance of each region

    ! Parametros de la simulacion
    integer(kind=int32), parameter :: nperbatch = 1E6           ! numero de historias por lote
    integer(kind=int32), parameter :: nbatch = 10               ! numero de lotes estadisticos
    integer(kind=int32), parameter :: nhist = nbatch*nperbatch  ! numero de historias total

    ! variables de conteo
    real(kind=real64), dimension(0:nreg+1) :: score, score2 = 0.0    ! score(0) : reflexion
                                                                     ! score(1:nreg) : absorcion
                                                                     ! score(nreg+1) : transmision

    real(kind=real64), dimension(0:nreg+1) :: mean_score = 0.0   ! valores promedio
    real(kind=real64), dimension(0:nreg+1) :: unc_score = 0.0    ! valores de incertidumbre

    integer :: case
    integer(kind=int32) :: i, ihist, ibatch     ! contadores de loops
    logical :: pdisc                            ! flag para descartar particula
    integer(kind=int32) :: irnew                ! indice de la region
    real(kind=real64) :: pstep                  ! distancia a la siguiente interaccion
    real(kind=real64) :: dist                   ! distancia al borde en la direccion de la particula
    real(kind=real64) :: rnno 
    real(kind=real64) :: max_var, fom
    real(kind=real64) :: start_time, end_time
    real(kind=real64) :: prec

    write(*,'(A)') '* *********************************** *'
    write(*,'(A)') '* Initializing Monte Carlo Simulation *'
    write(*,'(A)') '* *********************************** *'
    write(*,'(A)') 'This software estimates the probability of absorption, transmission and reflection'
    write(*,'(A)') 'Case 1: Total cross section = 2.0 cm-1, Scatter cross section = 0.2 cm-1, d = 5.0 cm, theta = 0.0'
    write(*,'(A)') 'Case 2: Total cross section = 2.0 cm-1, Scatter cross section = 0.8 cm-1, d = 5.0 cm, theta = 0.0'
    write(*,'(A)') 'Type 1 for case 1 or 2 for case 2: '
    read(*,*) case
    if(case == 1) then
        ! Caso 1)
        sigma_a = (/1.8, 1.8, 1.8, 1.8, 1.8/)  ! Seccion eficaz de absorcion (cm-1)
        sigma_s = (/0.2, 0.2, 0.2, 0.2, 0.2/)  ! Seccion eficaz de dispersion (cm-1)
    else 
        ! Caso 2)
        sigma_a = (/1.2, 1.2, 1.2, 1.2, 1.2/)
        sigma_s = (/0.8, 0.8, 0.8, 0.8, 0.8/) 
    endif

    call cpu_time(start_time)

    ! Inicializa RNG
    call rng_init(20180815)

    ! Impresion de informacion en pantalla
    write(*,'(A, I15)') 'Number of histories : ', nhist
    write(*,'(A, I15)') 'Number of batches : ', nbatch
    write(*,'(A, I15)') 'Number of histories per batch : ', nperbatch

    do i = 1,nreg
        write(*,'(A, I5, A)') 'For region ', i, ':'
        write(*,'(A, F15.5)') 'Total interaction cross-section (cm-1): ', sigma_t(i)
        write(*,'(A, F15.5)') 'Absoption interaction cross-section (cm-1): ', sigma_a(i)
        write(*,'(A, F15.5)') 'Scattering interaction cross-section (cm-1): ', sigma_s(i)
        write(*,'(A, F15.5)') '1D shield thickness (cm): ', xthick(i)
    enddo
    
    ! Inicializa la simulacion de la geometria
    write(*,'(A)') 'Region boundaries (cm):'
    write(*,'(F15.5)') xbounds(1)
    do i = 1,nreg
        xbounds(i+1) = xbounds(i) + xthick(i)
        write(*,'(F15.5)') xbounds(i+1)
    enddo

    ! Inicializacion de los datos para la tecnica de Splitting Geometrico:
    ! La importancia aumenta al aumentar el índice de la región para favorecer
    ! la transmision
    gs_i(1) = gs_r
    do i = 2,nreg
        gs_i(i) = gs_r*gs_i(i-1)            
    enddo

    write(*,'(A)') '(GS VRT ) Importances for each region:'
    do i = 1,nreg        
        write(*,'(A, I3, A, F15.5)') 'nreg = ', i, ', I = ', gs_i(i)
    enddo
    
    ibatch_loop: do ibatch = 1,nbatch
        ihist_loop: do ihist = 1,nperbatch
            
            ! Inicializa la historia
            np = 1
            x = xin
            u = uin
            wt = wtin
            ir = irin
            
            ! Definir flag de particula descartada
            pdisc = .false.

            ! Ingresa al proceso de transporte
            particle_loop: do
            
                ptrans_loop: do

                    ! Distancia a la siguiente interaccion
                    if(ir(np) == 0 .or. ir(np) == nreg+1) then
                        ! Vacuum step
                        pstep = 1.0E8
                    else
                        pstep = mfp(sigma_t(ir(np)))
                    endif

                    ! Guardar la region actual de la particula
                    irnew = ir(np)

                    ! Chequear si la particula sigue en la geometria
                    if(u(np) .lt. 0.0) then
                        if(irnew == 0) then
                            ! Particula deja la geometria: se descarta
                            pdisc = .true.
                        else
                            ! La particula va a la cara frontal de la region
                            dist = (xbounds(ir(np)) - x(np))/u(np)

                            ! Chequea si la particula deja la region
                            if(dist < pstep) then
                                pstep = dist                      
                                irnew = irnew - 1
                            endif
                        endif
                        
                    else if(u(np) .gt. 0.0) then
                        if(irnew == nreg+1) then
                            ! Particula deja la geometria: se descarta
                            pdisc = .true.
                        else
                            ! La particula va a la cara posterior de la region
                            dist = (xbounds(ir(np)+1) - x(np))/u(np)

                            ! Chequea si la particula deja la region
                            if(dist < pstep) then
                                pstep = dist
                                irnew = irnew + 1
                            endif
                        endif
                        
                    endif

                    ! Chequea si la particula esta descartada
                    if(pdisc .eqv. .true.) then
                        exit
                    endif

                    ! Transporte de la particula
                    x(np) = x(np) + pstep*u(np)

                    ! Si la particula no ha cambiado de region, interactua
                    if(ir(np) == irnew) then
                        exit
                    else
                        ! GEOMETRICAL SPLITTING
                        ! Implementation of geometrical splitting VRT.
                        gs_r = gs_i(irnew)/gs_i(ir(np))

                        if(gs_r > 1.0) then
                            ! Particle is going to the ROI. Perform particle splitting.
                            gs_n = floor(gs_r)
                            rnno = rng_set()

                            if(rnno .le. 1.0 - (gs_r - gs_n)) then
                                ! Divide the particle in n particles

                            else
                                ! Divide the particle in n+1 particles

                            endif
                        else
                            ! Particle is going backwards the ROI. Perform russian roulette.
                            rnno = rng_set()
                            if(rnno .gt. gs_r) then
                                ! particle does not survive, finish particle
                                np = np - 1
                                cycle
                            else
                                ! particle survives, adjusts weight accordingly and continue transport.
                                wt(np) = (1.0/gs_r)*wt(np)                        
                            endif
                        endif
                        
                        ! Update particle region index and continue transport process.
                        ir(np) = irnew
                    endif

                enddo ptrans_loop    
            
                if(pdisc .eqv. .true.) then
                    ! Particula descartada. Se cuenta y se detiene el rastreo
                    score(ir(np)) = score(ir(np)) + wt(np)
                    np = np - 1
                    
                    if(np .eq. 0) then
                        ! Finish particle history.
                        exit
                    else
                        ! Start transport of the next particle.
                        cycle
                    endif
                endif

                ! Determina el tipo de interaccion
                rnno = rng_set()
                if(rnno .le. sigma_a(ir(np))/sigma_t(ir(np))) then
                    ! Particula absorbida
                    score(ir(np)) = score(ir(np)) + wt(np)
                    np = np - 1

                    if(np .eq. 0) then
                        ! Finish particle history.
                        exit
                    else
                        ! Start transport of the next particle.
                        cycle
                    endif
                else
                    ! Particula dispersada, reingresa al loop de transporte con la nueva direccion
                    u(np) = scatt(u(np))
                endif
            
            enddo particle_loop
        enddo ihist_loop

        ! Acumula resultados y reinicializa el conteo
        mean_score = mean_score + score
        unc_score = unc_score + score**2

        score = 0.0
        score2 = 0.0

    enddo ibatch_loop

    ! Procesamiento estadistico
    mean_score = mean_score/nbatch
    unc_score = (unc_score - nbatch*mean_score**2)/(nbatch-1)
    unc_score = unc_score/nbatch
    unc_score = sqrt(unc_score)

    ! Calcula incertidumbre relativa para calcular FOM
    unc_score = unc_score/mean_score

    ! Imprime resultados en pantalla
    write(*,'(A,F10.5,A,F10.5,A)') 'Reflection : ', mean_score(0)/nperbatch, ' +/-', 100.0*unc_score(0), '%'

    ! Calcula la incertidumbre de absorcion. Se necesita combinar la incertidumbre de la deposicion en
    ! cada region
    write(*,'(A,F10.5,A,F10.5,A)') 'Absorption : ', sum(mean_score(1:nreg))/nperbatch, ' +/-', & 
        100.0*sum(unc_score(1:nreg)), '%'
    
    write(*,'(A,F10.5,A,F10.5,A)') 'Transmission : ', mean_score(nreg+1)/nperbatch, ' +/-', &
        100.0*unc_score(nreg+1), '%'

    ! Obtener tiempo de finalizacion
    call cpu_time(end_time)
    write(*,'(A,F15.5)') 'Elapsed time (s) : ', end_time - start_time

    ! Calculo de FOM, precision e incertimbre relativa
    max_var = maxval(unc_score)
    fom = 1.0/(max_var**2*(end_time - start_time))
    prec = sqrt(max_var)/maxval(mean_score/nperbatch)*100
    write(*,'(A,F15.5)') 'Mean : ', maxval(mean_score/nperbatch), 'SD : ', sqrt(max_var)
    write(*,'(A,F15.5)') 'Figure of merit (FOM) : ', fom
    write(*,'(A,F15.5)') 'Relative uncertainty (R) : ', prec/100
    write(*,'(A,F15.5)') 'Precission : ', prec, '%'

end program shield_1d
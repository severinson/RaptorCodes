export Decoder, add!, decode!, get_source, get_source!

"""
    Decoder{RT<:Row,VT,CODE<:Code}

Inactivation decoder. Compatible with Raptor10 (rfc5053) and RaptorQ (rfc6330)
codes.

"""
# TODO: Replace row type with coefficient type
# TODO: Replace rows with a QMatrix
# TODO: Give CT as parametric type instead of row
# TODO: Use sparse matrices to store row indices/coefs
mutable struct Decoder{RT<:Row,VT,CODE<:Code,SELECTOR<:Selector}
    p::CODE # type of code
    values::Vector{VT} # source values may be of any type, including arrays
    columns::Vector{Vector{Int}}
    rows::Vector{RT} # binary and q-ary codes use different row types
    dense::QMatrix{GF256} # dense (inactivated) symbols are stored separately
    colperm::Vector{Int} # maps column indices to their respective objects
    colperminv::Vector{Int} # maps column object indices to their column indices
    rowperm::Vector{Int} # maps row indices to their respective objects
    rowperminv::Vector{Int} # maps row object indices to their row indices
    uperm::Vector{Int} # maps ui to upi
    uperminv::Vector{Int} # maps upi to ui
    selector::SELECTOR # used to select which row to process next
    num_symbols::Int # code length
    num_decoded::Int # denoted by i in the R10 spec.
    num_inactivated::Int # denoted by u in the R10 spec.
    metrics::DataStructures.Accumulator{String,Int}
    status::String # indicates success or stores the reason for decoding failure.
    function Decoder{RT,VT,CODE,SELECTOR}(
        p::CODE,
        selector::Selector,
        num_symbols::Int) where {RT<:Row,VT,CODE<:Code,SELECTOR<:Selector}
        d = new(p,
                Vector{VT}(),
                [Vector{Int}() for _ in 1:num_symbols],
                Vector{RT}(),
                QMatrix{GF256}(64, num_symbols), # expanded once all rows have been added
                Vector(1:num_symbols),
                Vector(1:num_symbols),
                Vector{Int}(),
                Vector{Int}(),
                Vector{Int}(),
                Vector{Int}(),
                selector,
                num_symbols,
                0,
                0,
                DataStructures.counter(String),
                "")
        d.metrics["success"] = 0
        d.metrics["decoding_additions"] = 0
        d.metrics["decoding_multiplications"] = 0
        d.metrics["rowadds"] = 0
        d.metrics["rowmuls"] = 0
        d.metrics["inactivations"] = 0
        d.metrics["status"] = 0
        return d
    end
end

"""
    add!{RT,VT}(d::Decoder{RT,VT}, s::RT, v::VT)

Add a row, i.e., a linear equation of the source symbols, to the decoder.

"""
function add!{RT,VT}(d::Decoder{RT,VT}, row::RT, v::VT)
    # TODO: replace with two methods. one that only gives indices for
    # binary and one that gives both indiced and coefs for non-binary.
    if d.status != ""
        error("cannot add more symbols after decoding has failed")
    end
    push!(d.values, v)
    push!(d.rows, row)
    i = length(d.rowperm) + 1
    push!(d.rowperm, i)
    push!(d.rowperminv, i)
    push!(d.selector, d, i, row)
    for ci in neighbours(row)
        push!(d.columns[ci], i)
    end
end

"""
    add!{RT}(d::Decoder{RT}, s::CodeSymbol)

Add a code symbol to the decoder.

"""
function add!{RT}(d::Decoder{RT}, s::CodeSymbol)
    # TODO: call new add! methods
    add!(d, row(RT, s), s.value)
end

# the inactivated part is stored as dense bit vectors. these are indexed from
# the right of the matrix.
@inline _ci2ui(d::Decoder, ci::Int) = d.num_symbols-ci+1
@inline _ui2ci(d::Decoder, ui::Int) = d.num_symbols-ui+1

"""
    setdense!(d::Decoder, rpi::Int, cpi::Int, v)

Set the element of the dense matrix corresponding to permuted row and column
indices (rpi, cpi) to value v.

"""
function setdense!(d::Decoder{RT,VT}, rpi::Int, cpi::Int, v) where {RT,VT}
    # TODO: expand QMatrix on-demand
    row = d.rows[rpi]
    ci = d.colperminv[cpi]
    ui = _ci2ui(d, ci)
    upi = d.uperm[ui]
    # TODO: we shouldn't need this if
    if v isa Bool && v
        d.dense[upi,rpi] = GF256(1)
    else
        d.dense[upi,rpi] = v
    end
    return v
end

"""
    getdense!(d::Decoder, rpi::Int, cpi::Int)

Return the element of the dense matrix corresponding to permuted row and column
indices (rpi, cpi).

"""
function getdense(d::Decoder, rpi::Int, cpi::Int)
    row = d.rows[rpi]
    ci = d.colperminv[cpi]
    ui = _ci2ui(d, ci)
    if ui > length(d.uperm)
        return false # TODO: type instability
    end
    upi = d.uperm[ui]
    return d.dense[upi,rpi]
end

"""
    expand_dense(d::Decoder)

Expand the matrix storing inactivated symbols.

"""
function expand_dense!(d::Decoder)
    # TODO: doesn't carry over values
    m = 64
    while m < d.num_inactivated
        m *= 2
    end
    n = length(d.rows)
    if m == rows(d.dense) && n == cols(d.dense)
        return
    end
    d.dense = QMatrix{GF256}(m, n)
    println("creating ($m, $n) QMatrix")
    return
end

"""return the number of remaining source symbols to process in stage 1."""
function num_remaining(d::Decoder)
    return d.num_symbols - p.num_decoded - p.num_inactivated
end

"""check if an intermediate symbol is covered."""
@inline function iscovered(d::Decoder, i::Int) :: Bool
    return length(d.columns[i]) > 0
end

"""check if all intermediate symbols are covered."""
function check_cover(d::Decoder)
    for i in 1:d.num_symbols
        if !iscovered(d, i)
            push!(d.metrics, "status", -1)
            error("intermediate symbol with index $i not covered.")
        end
    end
end

"""swap cols ci and cj of the constraint matrix."""
@inline function swap_cols!(d::Decoder, ci::Int, cj::Int)
    d.colperm[ci], d.colperm[cj] = d.colperm[cj], d.colperm[ci]
    d.colperminv[d.colperm[ci]] = ci
    d.colperminv[d.colperm[cj]] = cj
end

"""swap cols ui and uj of the dense submatrix u."""
@inline function swap_dense_cols!(d::Decoder, ui::Int, uj::Int)
    d.uperm[ui], d.uperm[uj] = d.uperm[uj], d.uperm[ui]
    d.uperminv[d.uperm[ui]] = ui
    d.uperminv[d.uperm[uj]] = uj
end

"""swap rows ri and rj of the constraint matrix."""
@inline function swap_rows!(d::Decoder, ri::Int, rj::Int)
    d.rowperm[ri], d.rowperm[rj] = d.rowperm[rj], d.rowperm[ri]
    d.rowperminv[d.rowperm[ri]] = ri
    d.rowperminv[d.rowperm[rj]] = rj
end

"""zero out any elements of rows[rpi] below the diagonal"""
function zerodiag!(d::Decoder, rpi::Int) :: Int
    row = d.rows[rpi]
    zerodiag!(d, row, rpi)
    return rpi
end

function zerodiag!(d::Decoder, rowi::Row, rpi::Int)
    for (cpi, coef) in zip(neighbours(rowi), coefficients(rowi))
        zerodiag!(d, rowi, rpi, cpi, coef)
    end
    return rpi
end

function zerodiag!(d::Decoder, rowi::Row, rpi::Int, cpi::Int, coef)
    ci = d.colperminv[cpi]
    if ci < d.num_decoded+1 && ci <= d.num_symbols-d.num_inactivated
        rpj = d.rowperm[ci]
        rowj = d.rows[rpj]
        subtract!(d, rpj, rpi, coef, coefficient(rowj, cpi))
    end
end

"""
    subtract!(d::Decoder, rpi::Int, rpj::Int, coef)

Subtract coef*rows[rpi] from rows[rpj] and assign the result to rows[rpj]. New
row objects are only allocated when needed.

"""
function subtract!(d::Decoder, rpi::Int, rpj::Int, coef1)
    return subtract!(d, rpi, rpj, coef1, one(coef1))
end

"""
    subtract!(d::Decoder, rpi::Int, rpj::Int, coefi, coefj)

Subtract coefi/coefj*rows[rpi] from rows[rpj] and assign the result to
rows[rpj]. New row objects are only allocated when needed.

"""
function subtract!(d::Decoder, rpi::Int, rpj::Int, coefi, coefj)
    @assert !iszero(coefj) "coefj must be non-zero, but is $coefj and type $(typeof(coefj))"
    coef = coefi / coefj
    # d.rows[rpj] = subtract!(d.rows[rpj], d.rows[rpi], coef) # TODO: remove
    subtract!(d.dense, coef, rpj, rpi)
    if iszero(d.values[rpj])
        d.values[rpj] = zeros(d.values[rpi])
    end
    d.values[rpj] = subeq!(d.values[rpj], d.values[rpi], coef)
    update_metrics!(d, d.rows[rpi], coef)
    return
end

function subtract!(d::Decoder, rpi::Int, rpj::Int, coefi::Bool, coefj::Bool)
    @assert !iszero(coefj) "coefj must be non-zero, but is $coefj and type $(typeof(coefj))"
    # d.rows[rpj] = subtract!(d.rows[rpj], d.rows[rpi], coefi) # TODO: remove
    if !iszero(coefi)
        subtract!(d.dense, rpj, rpi)
    end
    if iszero(d.values[rpj])
        d.values[rpj] = zero(d.values[rpi])
    end
    d.values[rpj] = subeq!(d.values[rpj], d.values[rpi], coefi)
    update_metrics!(d, d.rows[rpi], coefi)
    return
end

"""track performance metrics"""
function update_metrics!(d::Decoder, row::Row, coef)
    if iszero(coef)
        return
    end
    weight = inactive_degree(row)
    push!(d.metrics, "decoding_additions", weight)
    push!(d.metrics, "rowadds", 1)
    if coef != one(coef)
        push!(d.metrics, "decoding_multiplications", weight)
        push!(d.metrics, "rowmuls", 1)
    end
    return
end

"""
    setinactive!(d, rpi::Int)

Set the dense elements of row rpi based on which columns have been inactivated.

"""
function setinactive!(d::Decoder, rpi::Int)
    row = d.rows[rpi]
    for (cpi, coef) in zip(neighbours(row), coefficients(row))
        ci = d.colperminv[cpi]
        if ci > d.num_symbols - d.num_inactivated
            setdense!(d, rpi, cpi, coef)
        end
    end
end

"""
    inactivate!(d::Decoder, cpi::Int)

Inactivate the column with permuted index cpi and update the priority of all
adjacent rows.

"""
function inactivate!(d::Decoder, cpi::Int)
    rightmost_active_col = d.num_symbols - d.num_inactivated
    ci = d.colperminv[cpi]
    if ci > rightmost_active_col
        return
    end
    push!(d.uperm, d.num_inactivated+1)
    push!(d.uperminv, d.num_inactivated+1)
    remove_column!(d.selector, d, cpi)
    d.num_inactivated += 1
    push!(d.metrics, "inactivations", 1)
    swap_cols!(d, ci, rightmost_active_col)
    return
end

"""
    vdegree(d::Decoder, row::Row)

Return the number of non-zero entries this row has in V.

"""
function vdegree(d::Decoder{RT}, row::RT) where RT
    deg = 0
    i::Int = d.num_decoded
    u::Int = d.num_inactivated
    L::Int = d.num_symbols
    for cpi in neighbours(row)
        ci = d.colperminv[cpi]
        deg += Int(i < ci <= L-u)
    end
    return deg
end

"""
    select_row(d::Decoder)

Remove a row from the selector and return its index. Used to select rows during
the diagonalization phase.

"""
function select_row(d::Decoder)
    # TODO: doesn't need to be a separate method
    return pop!(d.selector, d)
end

"""
    peel_row(d::Decoder, rpi::Int)

Peel away previously decoded symbols from a row. Has to be carried out each time
a row is selected.

"""
function peel_row!(d::Decoder, rpi::Int)
    setinactive!(d, rpi)
    zerodiag!(d, rpi)
end

"""
    diagonalize!(d::Decoder)

Perform row and column operations to put the submatrix consisting of the first
L-u columns into diagonal form. Referred to as the first phase in rfc6330.

"""
function diagonalize!(d::Decoder)
    expand_dense!(d)
    while d.num_decoded + d.num_inactivated < d.num_symbols

        ri = select_row(d)
        peel_row!(d, d.rowperm[ri])
        swap_rows!(d, ri, d.num_decoded+1)

        # swap any non-zero entry in V into the first column of V
        row = d.rows[d.rowperm[d.num_decoded+1]]
        active = neighbours(row)
        i = 1
        cpi = active[i]
        ci = d.colperminv[cpi]
        while !(d.num_decoded < ci <= d.num_symbols-d.num_inactivated) && i < length(active)
            i += 1
            cpi = active[i]
            ci = d.colperminv[cpi]
        end
        if !(d.num_decoded < ci <= d.num_symbols-d.num_inactivated)
            push!(d.metrics, "status", -3)
            error("incorrectly selected a row with no neighbours in V.")
        end
        swap_cols!(d, ci, d.num_decoded+1)
        remove_column!(d.selector, d, cpi)

        # inactivate the remaining neighbouring symbols
        rpi = d.rowperm[d.num_decoded+1]
        coefs = coefficients(d.rows[rpi])
        for j in i+1:length(active)
            cpi = active[j]
            ci = d.colperminv[cpi]
            if (d.num_decoded+1 < ci <= d.num_symbols-d.num_inactivated)
                inactivate!(d, cpi)
                setdense!(d, rpi, cpi, coefs[j])
            end
        end
        d.num_decoded += 1
    end
    return d
end

"""
    solve_dense!{RT<:QRow{Float64},VT}(d::Decoder{RT,VT})

Solve the dense system of equations consisting of the inactivated symbols using
least-squares. Applicable for real-number codes.

"""
function solve_dense!{RT<:QRow{Float64},VT}(d::Decoder{RT,VT})
    firstrow = d.num_decoded+1 # first row of the dense matrix
    lastrow = length(d.rows) # last row of the dense matrix
    firstcol = d.num_symbols-d.num_inactivated+1 # first column of the dense matrix
    lastcol = d.num_symbols # last column of the dense matrix
    @assert firstrow == firstcol "firstrow=$firstrow must be equal to firstcol=$firstcol"
    if lastrow-firstrow+1 < d.num_inactivated
        push!(d.metrics, "status", -4)
        error("least-squares failed. u_lower must at least as many rows as there are inactivations.")
    end

    # copy the matrix u_lower into a separate array
    A = zeros(
        eltype(VT),
        lastrow-firstrow+1,
        d.num_inactivated,
    )
    b = zeros(
        eltype(VT),
        lastrow-firstrow+1,
        length(d.values[1]), # assuming all entries have the same length
    )
    for ri in firstrow:lastrow
        rpi = d.rowperm[ri]
        peel_row!(d, rpi)
        for ci in firstcol:lastcol
            cpi = d.colperm[ci]
            A[ri-firstrow+1, ci-firstcol+1] = getdense(d, rpi, cpi)
        end
        b[ri-firstrow+1,:] = d.values[rpi]
    end

    # solve for x using least squares
    x = A\b

    # store the results and set the coefficients along the diagonal to 1.0
    for i in firstrow:lastcol
        rpi = d.rowperm[i]
        cpi = d.colperm[i]
        row = d.rows[rpi]
        d.rows[rpi] = QRow{Float64}(row.indices, row.values)
        setdense!(d, rpi, cpi, 1.0)
        d.values[rpi] = x[i-firstrow+1,:]
    end
    d.num_decoded += d.num_inactivated
    return d
end

"""
    solve_dense!(d::Decoder)

Solve for the inactivated symbols from the system of equations consisting of the
inactivated columns using Gaussian Elimination.

"""
function solve_dense!{RT,VT}(d::Decoder{RT,VT})

    for i in 1:d.num_inactivated

        # select the first row with non-zero inactive degree
        ci = d.num_decoded+1
        cpi = d.colperm[ci]
        ri = 0
        rpi = 0
        for rj in d.num_decoded+1:length(d.rows)
            rpj = d.rowperm[rj]
            peel_row!(d, rpj)

            # zero out the elements below the diagonal
            # TODO: call QMatrix getcolumn instead?
            for cj in d.num_symbols-d.num_inactivated+1:d.num_decoded
                cpj = d.colperm[cj]
                coef = getdense(d, rpj, cpj)
                if !iszero(coef)
                    rpk = d.rowperm[cj]
                    coef2 = getdense(d, rpk, cpj)
                    @assert !iszero(coef2) "coef2 must be non-zero. coef=$coef, coef2=$coef2, cj=$cj, cpj=$cpj"
                    subtract!(d, rpk, rpj, coef, coef2)
                end
            end
            if countnz(d.dense, rpj) > 0
                ri = rj
                rpi = rpj
                break
            end
        end
        if ri == 0
            push!(d.metrics, "status", -4)
            error("GE failed due to rank deficiency.")
        end
        swap_rows!(d, d.num_decoded+1, ri)

        # swap any non-zero entry into the i-th column of u_lower
        upi = findfirst(getcolumn(d.dense, rpi))
        @assert upi <= d.num_inactivated "$upi must be <= $(d.num_inactivated) row=$row"
        ui = d.uperminv[upi]
        cj = _ui2ci(d, ui)
        uj = _ci2ui(d, ci)
        swap_dense_cols!(d, ui, uj)
        swap_cols!(d, ci, cj)

        # subtract this row from all rows in u_lower above this one
        for rj in d.num_symbols-d.num_inactivated+1:d.num_decoded
            rpj = d.rowperm[rj]
            cpj = d.colperm[d.num_decoded+1]
            coef = getdense(d, rpj, cpj)
            if !iszero(coef)
                rpk = d.rowperm[d.num_decoded+1]
                subtract!(d, rpk, rpj, coef, getdense(d, rpk, cpj))
            end
        end
        d.num_decoded += 1
        ri = d.num_decoded
        rpi = d.rowperm[d.num_decoded]
        cpi = d.colperm[d.num_decoded]
        @assert !iszero(getdense(d, rpi, cpi)) "[$ri, $ri] is zero. row=$(d.rows[rpi])"
    end
    return d
end

"""
    backsolve!(d::Decoder)

Subtract the symbols decoded in solve_dense from the above rows of the
constraint matrix.

"""
function backsolve!(d::Decoder)
    for ri in 1:d.num_symbols-d.num_inactivated
        rpi = d.rowperm[ri]
        for (upi, coef) in enumerate(IndexLinear(), getcolumn(d.dense, rpi))
            if iszero(coef)
                continue
            end
            ui = d.uperminv[upi]
            ci = _ui2ci(d, ui)
            cpi = d.colperm[ci]
            rpj = d.rowperm[ci]
            subtract!(d, rpj, rpi, coef, getdense(d, rpj, cpi))
        end
    end
    return d
end

"""
    get_source{RT,VT}(d::Decoder{RT,VT})

Return the decoded intermediate symbols.

# TODO: intermediate() would be a better name. for systematic codes the source
symbols are the first K LT symbols.

"""
function get_source{RT,VT}(d::Decoder{RT,VT})
    C = Vector{VT}(d.num_symbols)
    return get_source!(C, d)
end

"""
    get_source!{RT,VT}(C::Vector, d::Decoder{RT,VT})

In-place version of get_source()

"""
function get_source!{RT,VT}(C::AbstractArray{VT}, d::Decoder{RT,VT})
    if length(C) != d.num_symbols
        error("C must have length num_symbols")
    end
    for i in 1:d.num_symbols-d.num_inactivated
        rpi = d.rowperm[i]
        cpi = d.colperm[i]
        coef = coefficient(d.rows[rpi], cpi)
        if coef == one(coef)
            C[cpi] = d.values[rpi]
        else
            C[cpi] = d.values[rpi] / coef
        end
    end
    for i in d.num_symbols-d.num_inactivated+1:d.num_symbols
        rpi = d.rowperm[i]
        cpi = d.colperm[i]
        coef = getdense(d, rpi, cpi)
        if coef == one(coef)
            C[cpi] = d.values[rpi]
        else
            C[cpi] = d.values[rpi] / coef
        end
    end
    return C
end

"""
    decode!{RT,VT}(d::Decoder{RT,VT}, raise_on_error=true)

Decode the source symbols. Raise an exception on decoding failure if
raise_on_error is true.

"""
function decode!{RT,VT}(d::Decoder{RT,VT}, raise_on_error=true)
    try
        check_cover(d)
        diagonalize!(d)
        solve_dense!(d)
        backsolve!(d)
        d.metrics["success"] = 1
        return get_source(d)
    catch err
        if isa(err, ErrorException)
            d.status = err.msg
            if raise_on_error
                rethrow(err)
            end
        else
            rethrow(err)
        end
    end
    Vector{VT}(d.p.K)
end

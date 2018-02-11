using DataStructures

mutable struct Decoder{RT}
    p::Parameters # TODO: Make parametric
    isymbols::Vector{ISymbol}
    csymbols::Vector{RT}
    iperm::Vector{Int} # map from columns indices to intermediate symbols
    iperminv::Vector{Int} # inverse column permutation
    cperm::Vector{Int} # map from row indices to encoded symbols
    cperminv::Vector{Int} # inverse row permutation
    pq::PriorityQueue{Int,Float64} # used to select rows
    num_decoded::Int # denoted by i in the R10 spec.
    num_inactivated::Int # denoted by u in the R10 spec.
    metrics::DataStructures.Accumulator
    status::String
    function Decoder{RT}(p::Parameters) where RT
        d = new(
            p,
            [ISymbol(0) for _ in 1:p.L],
            Vector{RT}(0),
            Vector(1:p.L),
            Vector(1:p.L),
            Vector{Int}(),
            Vector{Int}(),
            PriorityQueue{Int,Float64}(),
            0,
            0,
            DataStructures.counter(String),
            "",
        )
        d.metrics["success"] = 0
        d.metrics["num_xor"] = 0
        return d
    end
end

doc"R10 decoder constructor. Automatically adds constraint symbols."
function Decoder(p::R10Parameters)
    d = Decoder{R10Symbol}(p)
    C = [ISymbol(0) for _ in 1:p.L]
    r10_ldpc_encode!(C, p)
    r10_hdpc_encode!(C, p)
    for i in (p.K+1):(p.K+p.S+p.H)
        is = C[i]
        neighbours = push!([v for v in is.neighbours], i)
        cs = R10Symbol(-1, 0, neighbours)
        add!(d, cs)
    end
    return d
end

doc"Number of remaining source symbols to process in stage 1."
function num_remaining(d::Decoder)
    return d.p.L - p.num_decoded - p.num_inactivated
end

doc"Add a coded symbol to the decoder."
function add!(d::Decoder, s::R10Symbol)
    push!(d.csymbols, s)
    i = length(d.cperm) + 1
    enqueue!(d.pq, i, active_degree(s))
    push!(d.cperm, i)
    push!(d.cperminv, i)
    for j in s.active_neighbours
        push!(d.isymbols[j].neighbours, i)
    end
    for j in s.inactive_neighbours
        push!(d.isymbols[j].neighbours, i)
    end
    return
end

doc"Check if an intermediate symbol is covered."
function iscovered(d::Decoder, i::Int) :: Bool
    is = d.isymbols[i]
    return degree(is) > 0
end

doc"Check if all intermediate symbols are covered."
function check_cover(d::Decoder)
    for i in 1:d.p.L
        if !iscovered(d, i)
            error("intermediate symbol with index $i not covered.")
        end
    end
end

doc"Swap cols i and j of the constraint matrix."
function swap_cols!(d::Decoder, i::Int, j::Int)
    d.iperm[i], d.iperm[j] = d.iperm[j], d.iperm[i]
    d.iperminv[d.iperm[i]] = i
    d.iperminv[d.iperm[j]] = j
end

doc"Swap rows i and j of the constraint matrix."
function swap_rows!(d::Decoder, i::Int, j::Int)
    d.cperm[i], d.cperm[j] = d.cperm[j], d.cperm[i]
    d.cperminv[d.cperm[i]] = i
    d.cperminv[d.cperm[j]] = j
end

function priority(cs::R10Symbol, p::Parameters) :: Float64
    return active_degree(cs) + inactive_degree(cs) / p.L
end

doc"The R10 spec. gives a recommendation for which row to select in the case
    where the row with smallest active degree is 2."
function select_row_2(d::Decoder) :: Int
    _, v = peek(d.pq)
    if !(2 <= v < 3)
        error("function may only be called when 2 is the smallest active degree.")
    end

    # the coded symbols of active degree 2 are the edges
    edges = Vector{Int}()
    while length(d.pq) > 0
        _, v = peek(d.pq)
        if !(2 <= v < 3)
            break
        end
        push!(edges, dequeue!(d.pq))
    end
    # println("edges", edges)

    # the nodes correspond to the intermediate symbols
    nodes = Set{Int}()
    a = IntDisjointSets(d.p.L)
    size = zeros(Int, d.p.L)
    max_root = 0
    max_root_size = 0
    for edge in edges
        cs = d.csymbols[edge]
        if active_degree(cs) != 2
            error("wrong active degree. is $(active_degree(cs)). should be 2.")
        end
        n1, n2 = active_neighbours(cs)
        union!(a, n1, n2)
        push!(nodes, n1)
        push!(nodes, n2)
    end
    # println("nodes ", nodes)

    for node in nodes
        root = find_root(a, node)
        size[root] += 1
        if size[root] > max_root_size
            max_root = root
            max_root_size = size[root]
        end
    end
    node = max_root
    n = neighbours(d.isymbols[node])
    result = 0
    for edge in edges
        if edge in n
            result = edge
        end
    end
    if result == 0
        error("could not find neighbouring row")
    end

    for edge in edges
        if edge != result
            enqueue!(d.pq, edge, priority(d.csymbols[edge], d.p))
        end
    end

    return d.cperminv[result]
end

doc"Select the row with smallest active degree. TODO: Not according to the R10 spec."
function select_row(d::Decoder) :: Int
    # R10 spec. gives a special case for when 2 is the smallest active degree.
    _, v = peek(d.pq)
    if (2 <= v < 3)
        return select_row_2(d)
    end

    k = 0 # coded symbol index
    v = 0 # coded symbol priority
    while length(d.pq) > 0 && v < 1
        _, v = peek(d.pq)
        k = dequeue!(d.pq)
    end
    if k == 0
        error("no coded symbols of non-zero weight")
    end
    return d.cperminv[k]
end

doc"XOR of 2 sets."
function setxor(s1::Set, s2::Set) :: Set
    return union(setdiff(s1, s2), setdiff(s2, s1))
end

doc"XOR of 2 sorted lists."
function listxor(l1::Array, l2::Array, fa::Function, fr::Function) :: Array
    i = 1
    j = 1
    il, jl = length(l1), length(l2)
    l = similar(l1, 0)
    while i <= il && j <= jl
        @inbounds u, v = l1[i], l2[j]
        if u < v
            push!(l, u) # TODO: slow
            i += 1
        elseif u > v
            push!(l, v)
            fa(v)
            j += 1
        else
            fr(u)
            i += 1
            j += 1
        end
    end
    while i <= il
        @inbounds u = l1[i]
        push!(l, u) # TODO: slow
        i += 1
    end
    while j <= jl
        @inbounds v = l2[j]
        push!(l, v)
        fa(v)
        j += 1
    end
    return l
end

doc"Link an intermediate symbol to an outer code symbol."
function link_isymbol!(d::Decoder, i::Int, j::Int)
    push!(d.isymbols[i].neighbours, j)
end

doc"Unlink an intermediate symbol from an outer code symbol."
function unlink_isymbol!(d::Decoder, i::Int, j::Int)
    delete!(d.isymbols[i].neighbours, j)
end

doc"subtract csymbols[i] from csymbols[j]. update the isymbols accordingly.."
function subtract!(d::Decoder, i::Int, j::Int)
    cs1 = d.csymbols[i]
    cs2 = d.csymbols[j]
    active_neighbours = listxor(
        cs2.active_neighbours,
        cs1.active_neighbours,
        x->link_isymbol!(d, x, j),
        x->unlink_isymbol!(d, x, j),
    )
    inactive_neighbours = listxor(
        cs2.inactive_neighbours,
        cs1.inactive_neighbours,
        x->link_isymbol!(d, x, j),
        x->unlink_isymbol!(d, x, j),
    )
    value = xor(cs1.value, cs2.value)
    push!(d.metrics, "num_xor", degree(cs1)+1)
    cs = R10Symbol(
        -1,
        value,
        -1,
        active_neighbours,
        inactive_neighbours,
        false,
    )
    d.csymbols[j] = cs
    if j in keys(d.pq)
        d.pq[j] = priority(cs, d.p)
    end
    return
end

doc"True if cs neighbours the intermediate symbol with index i."
function has_neighbour(cs::R10Symbol, i::Int) :: Bool
    return (i in cs.active_neighbours) || (i in cs.inactive_neighbours)
end

doc"Inactivate a column of the constraint matrix."
function inactivate_isymbol!(d::Decoder, i::Int)
    is = d.isymbols[i]
    for j in neighbours(is)
        cs = d.csymbols[j]
        active_neighbours = [v for v in cs.active_neighbours if v != i]
        d.csymbols[j] = R10Symbol(
            -1,
            cs.value,
            -1,
            active_neighbours,
            push!(cs.inactive_neighbours, i),
        )
        if j in keys(d.pq)
            d.pq[j] = priority(d.csymbols[j], d.p)
        end
    end
end

function print_state(d::Decoder)
    return
    println("------------------------------")
    println("I=", d.num_decoded, " u=", d.num_inactivated)
    println(d.pq)
    for i in 1:length(d.iperm)
        @printf "%d:%d " i d.iperm[i]
    end
    println()
    for i in 1:length(d.iperminv)
        @printf "%d:%d " i d.iperminv[i]
    end
    println()
    for i in 1:length(d.cperm)
        cs = d.csymbols[d.cperm[i]]
        @printf "%d\t[" d.cperm[i]
        for j in 1:length(d.iperm)
            if has_neighbour(cs, d.iperm[j])
                @printf "1 "
            else
                @printf "0 "
            end
        end
        @printf "] = %d\n" cs.value
    end
    println("------------------------------")
end

doc"Perform row/column operations such that there are non-zero entries only
    along the diagonal and in the rightmost d.num_inactivated columns."
function diagonalize!(d::Decoder)
    while d.num_decoded + d.num_inactivated < d.p.L
        print_state(d)

        # select a row and swap it with the topmost row of V
        row = select_row(d) # TODO: slow
        swap_rows!(d, row, d.num_decoded+1)

        # find the corresponding coded symbol
        cs = d.csymbols[d.cperm[d.num_decoded+1]]

        # swap any non-zero entry into the first column of V
        is_indices = active_neighbours(cs)
        col = d.iperminv[is_indices[1]]
        swap_cols!(d, col, d.num_decoded+1)

        # inactivate the remaining neighbouring symbols
        for i in 2:length(is_indices)
            j = is_indices[i]
            rightmost_active_col = length(d.isymbols) - d.num_inactivated
            col = d.iperminv[j]
            if col <= rightmost_active_col
                swap_cols!(d, col, rightmost_active_col)
                d.num_inactivated += 1
                inactivate_isymbol!(d, j)
            end
        end

        # zero out entries below the diagonal of the first column of V
        for i in d.isymbols[d.iperm[d.num_decoded+1]].neighbours
            if d.cperminv[i] == d.num_decoded + 1
                continue
            end
            subtract!(d, d.cperm[d.num_decoded+1], i) # TODO: slow
        end
        d.num_decoded += 1

        print_state(d)
    end
    return d
end

doc"Solve for the inactivated intermediate symbols using GE."
function gaussian_elimination!(d::Decoder)
    for i in 1:d.num_inactivated

        # find any coded symbol of non-zero degree neighbouring only inactivated
        # intermediate symbols. swap this row with the first row.
        row = d.num_decoded + i
        cs = d.csymbols[d.cperm[row]]
        while degree(cs) == 0
            row += 1
            if row > length(d.csymbols)
                error("Gaussian elimination failed. constraint matrix not of full rank.")
            end
            cs = d.csymbols[d.cperm[row]]
        end
        current_row = d.num_decoded + i
        swap_rows!(d, current_row, row)

        cols = neighbours(cs)
        col = d.iperminv[cols[1]]
        current_col = current_row
        swap_cols!(d, current_col, col)

        # subtract this row from all other rows in the system.
        for j in d.isymbols[d.iperm[d.num_decoded+i]].neighbours
            if d.cperminv[j] < d.num_decoded
                continue
            elseif d.cperminv[j] == d.num_decoded + i
                continue
            end
            subtract!(d, d.cperm[d.num_decoded+i], j)
        end
    end
    return d
end

doc"Backsolve using the symbols decoded via GE."
function backsolve!(d::Decoder)
    for i in 1:d.num_inactivated
        row = d.cperm[d.num_decoded+i]
        cs = d.csymbols[row]
        for j in d.isymbols[d.iperm[d.num_decoded+i]].neighbours
            if d.cperminv[j] == d.num_decoded + i
                continue
            end
            subtract!(d, d.cperm[d.num_decoded+i], j)
        end
    end
    return d
end

doc"Get the decoded source symbols."
function get_source(d::Decoder)
    C = Array{Int,1}(d.p.K)
    for i in 1:d.p.K
        is = d.isymbols[i]
        if degree(is) != 1
            continue
            # error("source symbol with index $i not decoded")
        end
        col = neighbours(is)[1]
        cs = d.csymbols[col]
        if degree(cs) != 1
            continue
            # error("source symbol with index $i not decoded")
        end
        C[i] = cs.value
    end
    return C
end

doc"Carry out the decoding."
function decode!(d::Decoder, raise_on_error=true)
    try
        check_cover(d)
        diagonalize!(d)
        gaussian_elimination!(d)
        backsolve!(d)
        d.metrics["success"] = 1
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
    return get_source(d)
end

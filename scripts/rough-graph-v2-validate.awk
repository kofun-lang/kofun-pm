# Compare one normalized requirements-v2 plan with one fully store-validated
# lock-v2 graph plan. Inputs have already passed their canonical grammars and
# descriptor checks. Run with LC_ALL=C.

BEGIN {
    FS = "\t"
    OFS = "\t"
    max_identities = 1024
    max_pairs = 16384
    max_edges = 16384
}

function reject(message) {
    if (!bad)
        printf "rough-graph-v2: %s\n", message > "/dev/stderr"
    bad = 1
}

function pair(id, release) {
    return id SUBSEP release
}

function version_compare(left, right, a, b, i) {
    split(left, a, "\\.")
    split(right, b, "\\.")
    for (i = 1; i <= 3; i++) {
        if ((a[i] + 0) < (b[i] + 0)) return -1
        if ((a[i] + 0) > (b[i] + 0)) return 1
    }
    return 0
}

function pair_less(left_id, left_version, right_id, right_version) {
    if (left_id < right_id) return 1
    if (left_id > right_id) return 0
    return version_compare(left_version, right_version) < 0
}

function heap_swap(left, right, id, release) {
    id = heap_id[left]
    release = heap_version[left]
    heap_id[left] = heap_id[right]
    heap_version[left] = heap_version[right]
    heap_id[right] = id
    heap_version[right] = release
}

function enqueue(id, release, key, position, parent) {
    key = pair(id, release)
    if ((key in reachable) || (key in pending)) return 0
    pending[key] = 1
    heap_size++
    position = heap_size
    heap_id[position] = id
    heap_version[position] = release
    while (position > 1) {
        parent = int(position / 2)
        if (!pair_less(heap_id[position], heap_version[position],
            heap_id[parent], heap_version[parent]))
            break
        heap_swap(position, parent)
        position = parent
    }
    return 1
}

function pop_min(position, left, right, smallest, key) {
    popped_id = heap_id[1]
    popped_version = heap_version[1]
    key = pair(popped_id, popped_version)
    delete pending[key]
    if (heap_size == 1) {
        delete heap_id[1]
        delete heap_version[1]
        heap_size = 0
        return
    }
    heap_id[1] = heap_id[heap_size]
    heap_version[1] = heap_version[heap_size]
    delete heap_id[heap_size]
    delete heap_version[heap_size]
    heap_size--
    position = 1
    while (1) {
        left = position * 2
        right = left + 1
        smallest = position
        if (left <= heap_size &&
            pair_less(heap_id[left], heap_version[left],
                heap_id[smallest], heap_version[smallest]))
            smallest = left
        if (right <= heap_size &&
            pair_less(heap_id[right], heap_version[right],
                heap_id[smallest], heap_version[smallest]))
            smallest = right
        if (smallest == position) break
        heap_swap(position, smallest)
        position = smallest
    }
}

function mark_reachable(id, release, key) {
    key = pair(id, release)
    if (key in reachable) return 0
    reachable[key] = 1
    reachable_count++
    reachable_id[reachable_count] = id
    reachable_version[reachable_count] = release
    if (!(id in remote_identity_seen)) {
        remote_identity_seen[id] = 1
        remote_identity_count++
        remote_identity_order[remote_identity_count] = id
        maximum_reachable[id] = release
    } else if (version_compare(release, maximum_reachable[id]) > 0) {
        maximum_reachable[id] = release
    }
    return 1
}

$1 == "requirements" {
    requirements_digest = $7
    next
}

$1 == "root" {
    root_count++
    requirement_edge_count++
    start_count++
    start_id[start_count] = $2
    start_version[start_count] = $3
    next
}

$1 == "member" {
    member_count++
    member[$2] = 1
    member_order[member_count] = $2
    next
}

$1 == "member-requirement" {
    member_requirement_count++
    requirement_edge_count++
    start_count++
    start_id[start_count] = $4
    start_version[start_count] = $5
    next
}

$1 == "lock" {
    lock_requirements_digest = $6
    next
}

$1 == "package" {
    package_count++
    package_order[package_count] = $2
    package_state[$2] = $8
    package_version[$2] = $3
    next
}

$1 == "metadata" {
    metadata_count++
    key = pair($2, $3)
    metadata[key] = 1
    metadata_id[metadata_count] = $2
    metadata_version[metadata_count] = $3
    next
}

$1 == "dependency" {
    dependency_count++
    dependency_owner_id[dependency_count] = $2
    dependency_owner_version[dependency_count] = $3
    dependency_id[dependency_count] = $4
    dependency_version[dependency_count] = $5
    owner_key = pair($2, $3)
    if (!(owner_key in dependency_head))
        dependency_head[owner_key] = dependency_count
    else
        dependency_next[dependency_tail[owner_key]] = dependency_count
    dependency_tail[owner_key] = dependency_count
    next
}

$1 == "file" { next }

{
    reject("normalized input contains an unknown row kind: " $1)
}

END {
    if (requirements_digest == "" || lock_requirements_digest == "")
        reject("normalized plans did not retain both requirements digests")
    else if (requirements_digest != lock_requirements_digest)
        reject("requirements digest mismatch survived the lock-plan precedence gate")
    if (bad) exit 1

    for (i = 1; i <= member_count; i++) {
        id = member_order[i]
        if (!(id in package_state)) {
            reject("workspace member is missing from lock packages: " id)
            break
        }
        if (package_state[id] != "workspace") {
            reject("declared workspace member is not a workspace lock package: " id)
            break
        }
    }
    if (!bad) {
        for (i = 1; i <= package_count; i++) {
            id = package_order[i]
            if (package_state[id] == "workspace" && !(id in member)) {
                reject("lock workspace package is not a declared member: " id)
                break
            }
        }
    }
    if (bad) exit 1

    total_edges = requirement_edge_count + dependency_count
    if (total_edges > max_edges)
        reject("root, member, and remote dependency edges exceed 16384: " total_edges)
    if (bad) exit 1

    for (i = 1; i <= start_count; i++)
        if (!(start_id[i] in member))
            enqueue(start_id[i], start_version[i])

    while (heap_size) {
        pop_min()
        mark_reachable(popped_id, popped_version)
        owner_key = pair(popped_id, popped_version)
        edge = dependency_head[owner_key]
        while (edge) {
            if (!(dependency_id[edge] in member))
                enqueue(dependency_id[edge], dependency_version[edge])
            edge = dependency_next[edge]
        }
    }

    if (reachable_count > max_pairs)
        reject("distinct reachable identity/version pairs exceed 16384: " reachable_count)
    if (remote_identity_count + member_count > max_identities)
        reject("package identities including workspace exceed 1024: " (remote_identity_count + member_count))
    if (bad) exit 1

    for (i = 1; i <= reachable_count; i++) {
        key = pair(reachable_id[i], reachable_version[i])
        if (!(key in metadata)) {
            reject("reachable metadata is missing from lock: " reachable_id[i] "@" reachable_version[i])
            break
        }
    }
    if (!bad) {
        for (i = 1; i <= metadata_count; i++) {
            key = pair(metadata_id[i], metadata_version[i])
            if (!(key in reachable)) {
                reject("lock metadata is unreachable from supplied requirements: " metadata_id[i] "@" metadata_version[i])
                break
            }
        }
    }
    if (bad) exit 1

    for (i = 1; i <= remote_identity_count; i++) {
        id = remote_identity_order[i]
        if (!(id in package_state)) {
            reject("reachable remote identity is missing from lock packages: " id)
            break
        }
        if (package_state[id] != "selected") {
            reject("reachable remote identity is not selected in lock packages: " id)
            break
        }
    }
    if (!bad) {
        for (i = 1; i <= package_count; i++) {
            id = package_order[i]
            if (package_state[id] == "selected" && !(id in remote_identity_seen)) {
                reject("selected lock package is unreachable from supplied requirements: " id)
                break
            }
        }
    }
    if (!bad) {
        for (i = 1; i <= remote_identity_count; i++) {
            id = remote_identity_order[i]
            if (package_version[id] != maximum_reachable[id]) {
                reject("selected version is not the semantic maximum reachable requirement: " id " selected " package_version[id] " maximum " maximum_reachable[id])
                break
            }
        }
    }
    if (bad) exit 1

    print "summary", root_count + 0, member_count + 0, reachable_count + 0,
        remote_identity_count + 0, total_edges + 0
}

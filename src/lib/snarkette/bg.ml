open Core_kernel
open Fold_lib

let ( = ) = `Don't_use_polymorphic_equality

module type Backend_intf = sig

  module N : Nat_intf.S

  module Fq : Fields.Fp_intf with type nat := N.t

  module Fqe : Fields.Extension_intf with type base = Fq.t

  module G1 : sig
    type t [@@deriving sexp, bin_io]

    val zero : t

    val to_affine_coordinates : t -> Fq.t * Fq.t

    val is_well_formed : t -> bool

    val ( * ) : N.t -> t -> t

    val ( + ) : t -> t -> t
  end

  module G2 : sig
    type t [@@deriving sexp, bin_io]

    val to_affine_coordinates : t -> Fqe.t * Fqe.t

    val ( + ) : t -> t -> t

    val is_well_formed : t -> bool
  end

  val hash :
    a:G1.t -> b:G2.t -> c:G1.t -> h_delta_prime:G2.t -> G1.t
  
  module Fq_target : sig
    include Fields.Degree_2_extension_intf with type base = Fqe.t

    val unitary_inverse : t -> t
  end

  module Pairing :
    Pairing.S
    with module G1 := G1
     and module G2 := G2
     and module Fq_target := Fq_target
end

module Make (Backend : Backend_intf) = struct
  open Backend

  module Verification_key = struct
    type t =
      { g_alpha_h_beta: Fq_target.t 
      ; h_delta: G2.t
      ; query: G1.t array } 
    [@@deriving bin_io, sexp]

    let map_to_two t ~f =
      let xs, ys =
        List.fold_left t ~init:([], []) ~f:(fun (xs, ys) a ->
            let x, y = f a in
            (x :: xs, y :: ys) )
      in
      (List.rev xs, List.rev ys)

    let fold_bits {g_alpha_h_beta; h_delta; query}
        =
      let g1s = Array.to_list query in
      let g2s = [h_delta] in
      let gts = [Fq_target.unitary_inverse g_alpha_h_beta] in
      let g1_elts, g1_signs = map_to_two g1s ~f:G1.to_affine_coordinates in
      let non_zero_base_coordinate a =
        let x = Fqe.project_to_base a in
        assert (not (Fq.equal x Fq.zero)) ;
        x
      in
      let g2_elts, g2_signs =
        map_to_two g2s ~f:(fun g ->
            let x, y = G2.to_affine_coordinates g in
            (Fqe.to_base_elements x, non_zero_base_coordinate y) )
      in
      let gt_elts, gt_signs =
        map_to_two gts ~f:(fun g ->
            (* g is unitary, so (a, b) satisfy a quadratic over Fqe and thus
             b is determined by a up to sign *)
            let a, b = g in
            (Fqe.to_base_elements a, non_zero_base_coordinate b) )
      in
      let open Fold in
      let of_fq_list_list ls =
        let open Let_syntax in
        let%bind l = of_list ls in
        let%bind x = of_list l in
        Fq.fold_bits x
      in
      let parity_bit x = N.test_bit (Fq.to_bigint x) 0 in
      let parity_bits = Fn.compose (map ~f:parity_bit) of_list in
      concat_map (of_list g1_elts) ~f:Fq.fold_bits
      +> of_fq_list_list g2_elts +> of_fq_list_list gt_elts
      +> parity_bits g1_signs +> parity_bits g2_signs +> parity_bits gt_signs

    let fold t = Fold.group3 ~default:false (fold_bits t)

    module Processed = struct
      type t =
        { g_alpha_h_beta: Fq_target.t
        ; h_delta_pc: Pairing.G2_precomputation.t
        ; query: G1.t array }
      [@@deriving bin_io, sexp]

      let create {g_alpha_h_beta; h_delta; query}
          =
        { g_alpha_h_beta
        ; h_delta_pc = Pairing.G2_precomputation.create h_delta
        ; query }
    end
  end

  let check b lab = if b then Ok () else Or_error.error_string lab

  module Proof = struct
    type t = {a: G1.t; b: G2.t; c: G1.t; h_delta_prime: G2.t; z: G1.t} [@@deriving bin_io, sexp]

    let is_well_formed {a; b; c; h_delta_prime; z} =
      let open Or_error.Let_syntax in
      let err x =
        sprintf "proof was not well-formed (%s was off its curve)" x
      in
      let%bind () = check (G1.is_well_formed a) (err "a") in
      let%bind () = check (G2.is_well_formed b) (err "b") in
      let%bind () = check (G1.is_well_formed c) (err "c") in
      let%bind () = check (G2.is_well_formed h_delta_prime) (err "h_delta_prime") in
      let%map () = check (G1.is_well_formed z) (err "z") in
      ()
  end

  let verify (vk : Verification_key.Processed.t) input
      ({Proof.a; b; c; h_delta_prime; z} as proof) =
    let open Or_error.Let_syntax in
    let%bind () =
      check
        (Int.equal (List.length input) (Array.length vk.query - 1))
        "Input length was not as expected"
    in
    let%bind () = Proof.is_well_formed proof in
    let input_acc =
      List.foldi input ~init:vk.query.(0) ~f:(fun i acc x ->
          let q = vk.query.(1 + i) in
          G1.(acc + (x * q)) )
    in
    let h_delta_prime_pc = Pairing.G2_precomputation.create h_delta_prime
    in
    let test1 =
      let l =
        Pairing.unreduced_pairing a b 
      in
      let r1 = vk.g_alpha_h_beta in
      let r2 =
        Pairing.miller_loop
          (Pairing.G1_precomputation.create input_acc)
          vk.h_delta_pc
      in
      let r3 =
        Pairing.miller_loop (Pairing.G1_precomputation.create c) h_delta_prime_pc
      in
      let test =
        let open Fq_target in
        Pairing.final_exponentiation (unitary_inverse l * r2 * r3) * r1
      in
      Fq_target.(equal test one)
    in
    let%bind () = check test1 "First pairing check failed" in
    let test2 =
      let ys = hash ~a ~b ~c ~h_delta_prime in
      let l =
        Pairing.miller_loop (Pairing.G1_precomputation.create ys) h_delta_prime_pc
      in
      let r =
        Pairing.miller_loop (Pairing.G1_precomputation.create z) vk.h_delta_pc
      in
      let test2 =
        Pairing.final_exponentiation Fq_target.(l * unitary_inverse r)
      in
      Fq_target.(equal test2 one)
    in
    check test2 "Second pairing check failed"
end
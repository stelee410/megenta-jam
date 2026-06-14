// Adapted from demucs.cpp (https://github.com/sevagh/demucs.cpp, MIT) —
// cli-apps/threaded_inference.hpp, modified for MRT2-Jam: aggregated progress
// callback instead of per-thread stdout logging.
//
// Splits the song into N segments (0.75 s overlap), runs demucs_inference on
// each in parallel (the model is shared read-only), then recombines with a
// triangular overlap ramp.

#pragma once
#include "model.hpp"
#include "tensor.hpp"
#include <Eigen/Dense>
#include <atomic>
#include <cmath>
#include <thread>
#include <vector>

namespace demucscppthreaded {

const int SAMPLE_RATE = 44100;
const float OVERLAP = 0.75;
const int OVERLAP_SAMPLES = ::floorf(SAMPLE_RATE * OVERLAP);

inline Eigen::Tensor3dXf
threaded_inference(const struct demucscpp::demucs_model &model,
                   const Eigen::MatrixXf &full_audio, int num_threads,
                   demucscpp::ProgressCallback aggregate_cb) {
    // Per-thread progress, averaged into one callback.
    std::vector<std::atomic<float>> thread_progress(num_threads);
    for (auto &p : thread_progress) p.store(0.0f);
    std::atomic<bool> done{false};

    std::vector<demucscpp::ProgressCallback> cbs;
    for (int i = 0; i < num_threads; ++i) {
        cbs.push_back([i, &thread_progress](float progress, const std::string &) {
            thread_progress[i].store(progress);
        });
    }

    const int total_length = full_audio.cols();
    const int segment_length = ::ceilf((float)total_length / (float)num_threads);

    std::vector<Eigen::MatrixXf> segments;
    for (int i = 0; i < num_threads; ++i) {
        int start = i * segment_length;
        int end = std::min(total_length, start + segment_length);
        Eigen::MatrixXf segment =
            Eigen::MatrixXf::Zero(2, end - start + 2 * OVERLAP_SAMPLES);
        if (i == 0) {
            segment.block(0, 0, 2, OVERLAP_SAMPLES).colwise() = full_audio.col(0);
        } else {
            segment.block(0, 0, 2, OVERLAP_SAMPLES) =
                full_audio.block(0, start - OVERLAP_SAMPLES, 2, OVERLAP_SAMPLES);
        }
        if (i == num_threads - 1) {
            int remaining = total_length - end;
            segment.block(0, end - start + OVERLAP_SAMPLES, 2, remaining) =
                full_audio.block(0, end, 2, remaining);
        } else {
            segment.block(0, end - start + OVERLAP_SAMPLES, 2, OVERLAP_SAMPLES) =
                full_audio.block(0, end, 2, OVERLAP_SAMPLES);
        }
        segment.block(0, OVERLAP_SAMPLES, 2, end - start) =
            full_audio.block(0, start, 2, end - start);
        segments.push_back(segment);
    }

    std::vector<Eigen::Tensor3dXf> segment_outs(num_threads);
    std::vector<std::thread> threads;
    for (int i = 0; i < num_threads; ++i) {
        threads.emplace_back([&model, &segments, &segment_outs, i, &cbs]() {
            segment_outs[i] =
                demucscpp::demucs_inference(model, segments[i], cbs[i]);
        });
    }

    // Progress pump while workers run.
    std::thread pump([&]() {
        while (!done.load()) {
            float sum = 0.0f;
            for (auto &p : thread_progress) sum += p.load();
            if (aggregate_cb) aggregate_cb(sum / num_threads, "");
            std::this_thread::sleep_for(std::chrono::milliseconds(250));
        }
    });

    for (auto &t : threads) t.join();
    done.store(true);
    pump.join();

    const int nb_out_sources = model.is_4sources ? 4 : 6;
    Eigen::Tensor3dXf final_output(nb_out_sources, 2, total_length);
    final_output.setZero();

    Eigen::VectorXf ramp(segment_length);
    for (int i = 0; i < segment_length; ++i) {
        ramp(i) = std::min(i + 1, segment_length - i);
    }
    ramp /= ramp.maxCoeff();

    Eigen::VectorXf sum_weight = Eigen::VectorXf::Zero(total_length);
    for (size_t i = 0; i < segment_outs.size(); ++i) {
        const int segment_start = (int)i * segment_length;
        for (int t = 0; t < nb_out_sources; ++t) {
            for (int ch = 0; ch < 2; ++ch) {
                for (int j = 0; j < segment_length + 2 * OVERLAP_SAMPLES; ++j) {
                    const int global_idx = segment_start + j - OVERLAP_SAMPLES;
                    if (global_idx >= 0 && global_idx < total_length) {
                        float weight = 1.0f;
                        if (j < OVERLAP_SAMPLES) weight = ramp(j);
                        else if (j >= segment_length)
                            weight = ramp(segment_length + 2 * OVERLAP_SAMPLES - j - 1);
                        final_output(t, ch, global_idx) +=
                            segment_outs[i](t, ch, j) * weight;
                        sum_weight(global_idx) += weight;
                    }
                }
            }
        }
    }
    for (int t = 0; t < nb_out_sources; ++t) {
        for (int ch = 0; ch < 2; ++ch) {
            for (int i = 0; i < total_length; ++i) {
                if (sum_weight(i) > 0) {
                    final_output(t, ch, i) /=
                        (sum_weight(i) / (2.0f * (float)nb_out_sources));
                }
            }
        }
    }
    return final_output;
}

}  // namespace demucscppthreaded

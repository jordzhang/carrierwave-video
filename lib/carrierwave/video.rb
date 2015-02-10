require 'streamio-ffmpeg'
require 'carrierwave'
require 'carrierwave/video/ffmpeg_options'
require 'carrierwave/video/ffmpeg_theora'

module CarrierWave
  module Video
    extend ActiveSupport::Concern
    def self.ffmpeg2theora_binary=(bin)
      @ffmpeg2theora = bin
    end

    def self.ffmpeg2theora_binary
      @ffmpeg2theora.nil? ? 'ffmpeg2theora' : @ffmpeg2theora
    end

    module ClassMethods
      def encode_video(target_format, options={})
        process encode_video: [target_format, options]
      end

      def encode_ogv(opts={})
        process encode_ogv: [opts]
      end

    end

    def encode_ogv(opts)
      # move upload to local cache
      cache_stored_file! if !cached?

      tmp_path  = File.join( File.dirname(current_path), "tmpfile.ogv" )
      @options = CarrierWave::Video::FfmpegOptions.new('ogv', opts)

      with_trancoding_callbacks do
        transcoder = CarrierWave::Video::FfmpegTheora.new(current_path, tmp_path)
        transcoder.run(@options.logger(model))
        File.rename tmp_path, current_path
      end
    end

    def encode_video(format, opts={})
      # move upload to local cache
      cache_stored_file! if !cached?

      @options = CarrierWave::Video::FfmpegOptions.new(format, opts)
      tmp_path = File.join( File.dirname(current_path), "tmpfile.#{format}" )
      file = ::FFMPEG::Movie.new(current_path)

      if opts[:resolution] == :same
        @options.format_options[:resolution] = file.resolution
      end

      if opts[:video_bitrate] == :same
        @options.format_options[:video_bitrate] = file.video_bitrate
      end

      yield(file, @options.format_options) if block_given?

      progress = @options.progress(model)

      with_trancoding_callbacks do
        if progress
          file.transcode(tmp_path, @options.format_params, @options.encoder_options) {
              |value| progress.call(value)
          }
        else
          file.transcode(tmp_path, @options.format_params, @options.encoder_options)
        end
        File.rename tmp_path, current_path
      end
    end

    def video_replacement(format, opts={})
      # move upload to local cache
      cache_stored_file! if !cached?

      if opts[:replacement].present?
        replacement_path = nil
        if opts[:replacement].kind_of? Symbol
          replacement_path = model.send(opts[:replacement]).current_path
        elsif opts[:replacement].kind_of? String
          replacement_path = opts[:replacement]
        end

        if replacement_path.present?
          # split audio to mp3
          audio_path = File.join(File.dirname(current_path), "tmpfile.mp3")
          file = ::FFMPEG::Movie.new(current_path)
          file.transcode(audio_path, "-vn")

          avi_path = File.join(File.dirname(current_path), "tmpfile.avi")
          file.transcode(avi_path, "-an -vcodec libx264")

          ouput_path = File.join(File.dirname(current_path), "replacement_tmp.avi")
          system "#{CarrierWave::Video.replacement_binary} -i #{avi_path} -b #{replacement_path} -o #{ouput_path}"
          result_path = File.join(File.dirname(current_path), "tmpfile.mp4")

          movie = ::FFMPEG::Movie.new(ouput_path)
          movie.transcode(result_path, "-i #{audio_path} ")

          File.rename result_path, current_path
          # File.rm ouput_path
          # File.rm avi_path
          # File.rm audio_path
        end
      end


    end
    def self.replacement_binary=(bin)
      @replacement_binary = bin
    end

    # Get the path to the ffmpeg binary, defaulting to 'ffmpeg'
    #
    # @return [String] the path to the ffmpeg binary
    def self.replacement_binary
      @replacement_binary || 'chbg'
    end
    private
      def with_trancoding_callbacks(&block)
        callbacks = @options.callbacks
        logger = @options.logger(model)
        begin
          send_callback(callbacks[:before_transcode])
          setup_logger
          block.call
          send_callback(callbacks[:after_transcode])
        rescue => e
          send_callback(callbacks[:rescue])

          if logger
            logger.error "#{e.class}: #{e.message}"
            e.backtrace.each do |b|
              logger.error b
            end
          end

          raise CarrierWave::ProcessingError.new("Failed to transcode with FFmpeg. Check ffmpeg install and verify video is not corrupt or cut short. Original error: #{e}")
        ensure
          reset_logger
          send_callback(callbacks[:ensure])
        end
      end

      def send_callback(callback)
        model.send(callback, @options.format, @options.raw) if callback.present?
      end

      def setup_logger
        return unless @options.logger(model).present?
        @ffmpeg_logger = ::FFMPEG.logger
        ::FFMPEG.logger = @options.logger(model)
      end

      def reset_logger
        return unless @ffmpeg_logger
        ::FFMPEG.logger = @ffmpeg_logger
      end
  end
end
